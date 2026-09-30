import { afterEach, describe, expect, it } from "vitest";
import { CLOSE_REPLACED, CLOSE_UNAUTHORIZED } from "../src/presence.ts";
import { Client, DEV_TOKEN, participant, type Running, start } from "./helpers.ts";

let running: Running | undefined;
const clients: Client[] = [];
afterEach(async () => {
  for (const c of clients.splice(0)) c.socket.terminate();
  await running?.server.close();
  running = undefined;
});

async function connect(url = `${running!.ws}?token=${DEV_TOKEN}`): Promise<Client> {
  const c = await Client.open(url);
  clients.push(c);
  return c;
}

/** Connects and joins `room` as `id`, consuming the ack and the first list. */
async function joined(room: string, id: string): Promise<Client> {
  const c = await connect();
  c.send({ type: "join", id: 1, roomId: room, participant: participant(id) });
  expect(await c.next()).toEqual({ type: "ack", id: 1 });
  await c.nextIds();
  return c;
}

describe("auth", () => {
  it("closes with 4401 without a valid token", async () => {
    running = await start();
    for (const url of [running.ws, `${running.ws}?token=wrong`]) {
      const c = await connect(url);
      expect(await c.next()).toMatchObject({ type: "error", code: "unauthorized" });
      expect(await c.closed).toBe(CLOSE_UNAUTHORIZED);
    }
  });

  it("accepts an Authorization header instead of the query parameter", async () => {
    running = await start();
    const { WebSocket } = await import("ws");
    const socket = new WebSocket(running.ws, { headers: { Authorization: `Bearer ${DEV_TOKEN}` } });
    const message = await new Promise<string>((resolve) => {
      socket.on("open", () => socket.send(JSON.stringify({ type: "ping", id: 7 })));
      socket.on("message", (d) => resolve(d.toString()));
    });
    expect(JSON.parse(message)).toEqual({ type: "pong", id: 7 });
    socket.terminate();
  });

  it("refuses upgrades on other paths", async () => {
    running = await start();
    const c = new Client(`${running.base.replace("http", "ws")}/other?token=${DEV_TOKEN}`);
    await expect(c.opened).rejects.toThrow();
  });
});

describe("join, update, leave", () => {
  it("broadcasts the full participant list, including the receiver, in join order", async () => {
    running = await start();
    const alice = await connect();
    alice.send({ type: "join", id: 1, roomId: "r", participant: participant("alice") });
    expect(await alice.next()).toEqual({ type: "ack", id: 1 });
    expect(await alice.next()).toEqual({ type: "participants", roomId: "r", participants: [participant("alice")] });

    const bob = await connect();
    bob.send({ type: "join", id: "j", roomId: "r", participant: participant("bob") });
    expect(await bob.next()).toEqual({ type: "ack", id: "j" });
    expect(await bob.nextIds()).toEqual(["alice", "bob"]);
    expect(await alice.nextIds()).toEqual(["alice", "bob"]);
  });

  it("relays updates as-is, unknown fields included", async () => {
    running = await start();
    const alice = await joined("r", "alice");
    const bob = await joined("r", "bob");
    await alice.nextIds();

    const state = participant("bob", {
      sessionId: "sess1",
      tracks: { cam: { kind: "video", source: "camera" } },
      metadata: { displayName: "Bob" },
      futureField: [1, 2],
    });
    bob.send({ type: "update", id: 2, participant: state });
    expect(await bob.next((m) => m.type === "ack")).toEqual({ type: "ack", id: 2 });
    const list = await alice.next((m) => m.type === "participants");
    expect(list.participants).toEqual([participant("alice"), state]);
  });

  it("removes a participant on leave and tells the others", async () => {
    running = await start();
    const alice = await joined("r", "alice");
    const bob = await joined("r", "bob");
    await alice.nextIds();

    bob.send({ type: "leave", id: 3 });
    expect(await bob.next()).toEqual({ type: "ack", id: 3 });
    expect(await alice.nextIds()).toEqual(["alice"]);
    expect(running.server.presence.participantsIn("r").map((p) => p.participantId)).toEqual(["alice"]);

    // The same connection can join again.
    bob.send({ type: "join", id: 4, roomId: "r", participant: participant("bob") });
    expect(await bob.next((m) => m.type === "ack")).toEqual({ type: "ack", id: 4 });
    expect(await alice.nextIds()).toEqual(["alice", "bob"]);
  });

  it("removes a participant when its socket closes", async () => {
    running = await start();
    const alice = await joined("r", "alice");
    const bob = await joined("r", "bob");
    await alice.nextIds();
    bob.close();
    expect(await alice.nextIds()).toEqual(["alice"]);
  });

  it("forgets an empty room", async () => {
    running = await start();
    const alice = await joined("r", "alice");
    alice.send({ type: "leave" });
    await expect.poll(() => running!.server.presence.participantsIn("r")).toEqual([]);
  });
});

describe("errors", () => {
  it("rejects malformed messages without closing", async () => {
    running = await start();
    const c = await connect();
    c.send("not json");
    expect(await c.next()).toMatchObject({ type: "error", code: "bad_request" });
    c.send({ type: "bogus", id: 1 });
    expect(await c.next()).toMatchObject({ type: "error", id: 1, code: "bad_request" });
    for (const p of [null, {}, { participantId: "" }, { participantId: "a" }, participant("a", { sessionId: 3 })]) {
      c.send({ type: "join", id: 2, roomId: "r", participant: p });
      expect(await c.next(), JSON.stringify(p)).toMatchObject({ type: "error", id: 2, code: "bad_request" });
    }
    c.send({ type: "join", id: 3, roomId: "", participant: participant("a") });
    expect(await c.next()).toMatchObject({ type: "error", id: 3, code: "bad_request" });
    c.send({ type: "ping", id: 4 });
    expect(await c.next()).toEqual({ type: "pong", id: 4 });
  });

  it("rejects update before join, a changed participantId, and a second join", async () => {
    running = await start();
    const c = await connect();
    c.send({ type: "update", id: 1, participant: participant("a") });
    expect(await c.next()).toMatchObject({ type: "error", id: 1, code: "not_joined" });
    c.send({ type: "join", id: 2, roomId: "r", participant: participant("a") });
    await c.next((m) => m.type === "ack");
    c.send({ type: "update", id: 3, participant: participant("b") });
    expect(await c.next((m) => m.type === "error")).toMatchObject({ id: 3, code: "participant_id_changed" });
    c.send({ type: "join", id: 4, roomId: "r2", participant: participant("a") });
    expect(await c.next((m) => m.type === "error")).toMatchObject({ id: 4, code: "already_joined" });
  });
});

describe("reconnection and eviction", () => {
  it("lets a new connection with the same participantId replace the old one", async () => {
    running = await start();
    const alice = await joined("r", "alice");
    const old = await joined("r", "bob");
    await alice.nextIds();

    const fresh = await connect();
    fresh.send({ type: "join", id: 1, roomId: "r", participant: participant("bob", { sessionId: "new" }) });
    await fresh.next((m) => m.type === "ack");
    expect(await old.next((m) => m.type === "error")).toMatchObject({ code: "replaced" });
    expect(await old.closed).toBe(CLOSE_REPLACED);
    const list = await alice.next((m) => m.type === "participants");
    expect(list.participants).toEqual([participant("alice"), participant("bob", { sessionId: "new" })]);
    // The old socket closing doesn't remove the new member.
    expect(running.server.presence.participantsIn("r").map((p) => p.participantId)).toEqual(["alice", "bob"]);
  });

  it("evicts a socket that stops answering pings within about two heartbeats", async () => {
    running = await start({ heartbeatMs: 100 });
    const alice = await joined("r", "alice");
    const bob = await joined("r", "bob");
    await alice.nextIds();

    // Simulate a dead peer: its socket stays open but stops answering pings.
    // (ws answers pings automatically, so pause the underlying TCP socket.)
    const raw = (bob.socket as unknown as { _socket: { pause(): void } })._socket;
    raw.pause();
    const started = Date.now();
    expect(await alice.nextIds(2000)).toEqual(["alice"]);
    expect(Date.now() - started).toBeLessThan(1000);
    expect(running.logs.join("\n")).toContain("evicting unresponsive connection (bob)");
  });

  it("keeps live sockets that answer pings", async () => {
    running = await start({ heartbeatMs: 50 });
    await joined("r", "alice");
    await new Promise((r) => setTimeout(r, 300));
    expect(running.server.presence.participantsIn("r")).toHaveLength(1);
  });
});

describe("room isolation", () => {
  it("only tells members of the same room", async () => {
    running = await start();
    const a1 = await joined("room-a", "p1");
    const b1 = await joined("room-b", "p1"); // same participantId, different room: no conflict
    const a2 = await joined("room-a", "p2");
    expect(await a1.nextIds()).toEqual(["p1", "p2"]);
    a2.send({ type: "update", id: 9, participant: participant("p2", { sessionId: "x" }) });
    await a1.nextIds();
    b1.send({ type: "ping", id: 1 });
    // b1 got nothing from room-a: the only thing queued is the pong.
    expect(await b1.next()).toEqual({ type: "pong", id: 1 });
    expect(b1.messages).toEqual([]);
    expect(running.server.presence.participantsIn("room-b").map((p) => p.participantId)).toEqual(["p1"]);
  });
});
