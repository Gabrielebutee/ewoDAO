import { describe, expect, it } from "vitest";
import { Cl, ClarityType, ClarityValue, SomeCV, UIntCV } from "@stacks/transactions";

const contractName = "ewoDAO";
const MIN_PROPOSAL_STAKE = 1_000_000;
const VOTING_PERIOD = 1440;
const EXECUTION_DELAY = 144;

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const proposer = accounts.get("wallet_1")!;
const voterA = accounts.get("wallet_2")!;
const voterB = accounts.get("wallet_3")!;

const unwrapUint = (cv: unknown): number => {
  expect(cv).toHaveClarityType(ClarityType.UInt);
  return Number((cv as UIntCV).value);
};

const readOnly = (fn: string, args: ClarityValue[], sender = deployer) =>
  simnet.callReadOnlyFn(contractName, fn, args, sender).result;

const unwrapSomeTuple = (cv: unknown) => {
  expect(cv).toHaveClarityType(ClarityType.OptionalSome);
  const some = cv as SomeCV;
  const tuple = some.value as { value: Record<string, unknown> };
  return tuple.value;
};

const currentNextId = () =>
  unwrapUint(readOnly("get-next-proposal-id", []));

describe("ewoDAO governance flows", () => {
  it("creates proposals with the required stake and stores metadata", () => {
    const expectedId = currentNextId();

    const { result } = simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );
    expect(result).toBeOk(Cl.uint(expectedId));

    const proposal = readOnly("get-proposal", [Cl.uint(expectedId)]);
    const data = unwrapSomeTuple(proposal);

    expect(data.proposer).toBePrincipal(proposer);
    expect(data["proposal-stake"]).toBeUint(MIN_PROPOSAL_STAKE);
    expect(data.executed).toBeBool(false);
    expect(currentNextId()).toBe(expectedId + 1);
  });

  it("rejects proposals below the minimum stake", () => {
    const beforeId = currentNextId();

    const { result } = simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE - 1)],
      proposer,
    );
    expect(result).toBeErr(Cl.uint(4));
    expect(currentNextId()).toBe(beforeId);
  });

  it("records votes and prevents double voting", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    const vote = simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(true), Cl.uint(2)],
      voterA,
    );
    expect(vote.result).toBeOk(Cl.bool(true));

    const proposal = readOnly("get-proposal", [Cl.uint(proposalId)]);
    const data = unwrapSomeTuple(proposal);
    expect(data["votes-for"]).toBeUint(2);
    expect(data["votes-against"]).toBeUint(0);

    const storedVote = readOnly("get-vote", [Cl.uint(proposalId), Cl.standardPrincipal(voterA)]);
    expect(storedVote).toBeSome(Cl.tuple({ weight: Cl.uint(2) }));

    const duplicate = simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(true), Cl.uint(2)],
      voterA,
    );
    expect(duplicate.result).toBeErr(Cl.uint(3));
  });

  it("lets the owner pause and resume voting", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    const pause = simnet.callPublicFn(contractName, "toggle-voting-pause", [], deployer);
    expect(pause.result).toBeOk(Cl.bool(true));

    const blocked = simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(true), Cl.uint(1)],
      voterB,
    );
    expect(blocked.result).toBeErr(Cl.uint(12));

    const resume = simnet.callPublicFn(contractName, "toggle-voting-pause", [], deployer);
    expect(resume.result).toBeOk(Cl.bool(false));
  });

  it("allows emergency cancellation by the owner within the window", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    const beforeSlash = unwrapUint(readOnly("get-slashed-funds", []));

    const response = simnet.callPublicFn(
      contractName,
      "emergency-cancel-proposal",
      [Cl.uint(proposalId)],
      deployer,
    );
    expect(response.result).toBeOk(Cl.bool(true));

    const afterSlash = unwrapUint(readOnly("get-slashed-funds", []));
    expect(afterSlash).toBe(beforeSlash + MIN_PROPOSAL_STAKE / 2);

    const data = unwrapSomeTuple(readOnly("get-proposal", [Cl.uint(proposalId)]));
    expect(data.cancelled).toBeBool(true);
    expect(data["stake-slashed"]).toBeBool(true);
    expect(data["stake-returned"]).toBeBool(false);
  });

  it("cancels proposals via community threshold and slashes the full stake", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(true), Cl.uint(2)],
      voterA,
    );

    const beforeSlash = unwrapUint(readOnly("get-slashed-funds", []));

    const cancel = simnet.callPublicFn(
      contractName,
      "vote-to-cancel",
      [Cl.uint(proposalId), Cl.uint(2)],
      voterB,
    );
    expect(cancel.result).toBeOk(Cl.bool(true));

    const afterSlash = unwrapUint(readOnly("get-slashed-funds", []));
    expect(afterSlash).toBe(beforeSlash + MIN_PROPOSAL_STAKE);

    const data = unwrapSomeTuple(readOnly("get-proposal", [Cl.uint(proposalId)]));
    expect(data.cancelled).toBeBool(true);
    expect(data["stake-slashed"]).toBeBool(true);
    expect(data["cancellation-votes"]).toBeUint(2);
  });

  it("executes passing proposals after voting and execution delays and returns stake", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(true), Cl.uint(3)],
      voterA,
    );

    simnet.mineEmptyBlocks(VOTING_PERIOD + EXECUTION_DELAY + 1);

    const exec = simnet.callPublicFn(
      contractName,
      "execute-proposal",
      [Cl.uint(proposalId)],
      voterB,
    );
    expect(exec.result).toBeOk(Cl.bool(true));

    const data = unwrapSomeTuple(readOnly("get-proposal", [Cl.uint(proposalId)]));
    expect(data.executed).toBeBool(true);
    expect(data.cancelled).toBeBool(false);
    expect(data["stake-returned"]).toBeBool(true);
    expect(data["stake-slashed"]).toBeBool(false);
  });

  it("lets proposers withdraw stake from failed proposals after the delay", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    simnet.callPublicFn(
      contractName,
      "cast-vote",
      [Cl.uint(proposalId), Cl.bool(false), Cl.uint(1)],
      voterA,
    );

    simnet.mineEmptyBlocks(VOTING_PERIOD + EXECUTION_DELAY + 1);

    const withdraw = simnet.callPublicFn(
      contractName,
      "withdraw-failed-proposal-stake",
      [Cl.uint(proposalId)],
      proposer,
    );
    expect(withdraw.result).toBeOk(Cl.bool(true));

    const data = unwrapSomeTuple(readOnly("get-proposal", [Cl.uint(proposalId)]));
    expect(data.executed).toBeBool(false);
    expect(data.cancelled).toBeBool(false);
    expect(data["stake-returned"]).toBeBool(true);
    expect(data["stake-slashed"]).toBeBool(false);
  });

  it("withdraws slashed funds only for the owner and within balance", () => {
    const proposalId = currentNextId();
    simnet.callPublicFn(
      contractName,
      "create-proposal",
      [Cl.uint(MIN_PROPOSAL_STAKE)],
      proposer,
    );

    simnet.callPublicFn(
      contractName,
      "emergency-cancel-proposal",
      [Cl.uint(proposalId)],
      deployer,
    );

    const available = unwrapUint(readOnly("get-slashed-funds", []));

    const nonOwner = simnet.callPublicFn(
      contractName,
      "withdraw-slashed-funds",
      [Cl.standardPrincipal(voterA), Cl.uint(1_000)],
      voterA,
    );
    expect(nonOwner.result).toBeErr(Cl.uint(11));

    const amount = Math.min(available, 100_000);
    const ownerWithdraw = simnet.callPublicFn(
      contractName,
      "withdraw-slashed-funds",
      [Cl.standardPrincipal(proposer), Cl.uint(amount)],
      deployer,
    );
    expect(ownerWithdraw.result).toBeOk(Cl.bool(true));

    const remaining = unwrapUint(readOnly("get-slashed-funds", []));
    expect(remaining).toBe(available - amount);
  });
});
