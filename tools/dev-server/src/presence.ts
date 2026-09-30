/**
 * A minimal room-presence server over WebSocket, for development.
 *
 * It maps 1:1 to the Dart `Signaling` interface (join / update / leave, and a
 * participant list pushed on every change). Payloads are opaque
 * `ParticipantState.toJson()` objects; the server only checks their shape and
 * relays them. The protocol is documented in ../README.md.
 *
 * DEV ONLY: any holder of the dev token can join any room and read everyone's
 * presence. That is fine on a laptop; it is not an access-control model.
 */

import type { IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import { type RawData, WebSocket, WebSocketServer } from "ws";

/** Close code sent when the dev token is missing or wrong. Clients must not reconnect. */
export const CLOSE_UNAUTHORIZED = 4401;
/**
 * Close code sent when another connection joined the same room with the same
 * `participantId`. Clients must not reconnect (the newer connection wins).
 */
export const CLOSE_REPLACED = 4409;

/** Maximum size of one message, in bytes. */
export const MAX_MESSAGE_BYTES = 64 * 1024;
const MAX_ID_LENGTH = 256;

/** A `ParticipantState.toJson()` object, relayed as-is. */
export type ParticipantJson = Record<string, unknown> & { participantId: string };

/** Options for {@link PresenceServer}. */
export interface PresenceOptions {
  /** Whether a connection may be accepted, given the upgrade request. */
  authorize(request: IncomingMessage): boolean;
  /**
   * How often to ping each socket, in milliseconds. A socket that hasn't
   * answered (or sent anything) since the previous ping is dropped, so a dead
   * peer leaves its room within about twice this interval. Default 2000.
   */
  heartbeatMs?: number;
  /** Receives one-line, secret-free log messages. */
  log?: (message: string) => void;
}

interface Connection {
  readonly socket: WebSocket;
  alive: boolean;
  room: string | null;
  participantId: string | null;
}

interface Member {
  readonly connection: Connection;
  state: ParticipantJson;
}

/** Thrown for a malformed client message; becomes an `error` reply. */
class ProtocolError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

function isValidId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= MAX_ID_LENGTH &&
    !/[\u0000-\u001f\u007f]/.test(value);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Checks the `ParticipantState` wire shape loosely: the fields the server and peers rely on. */
function parseParticipant(value: unknown): ParticipantJson {
  if (!isObject(value)) throw new ProtocolError("bad_request", "participant must be an object");
  if (!isValidId(value.participantId)) {
    throw new ProtocolError("bad_request", "participant.participantId must be a non-empty string");
  }
  const sessionId = value.sessionId;
  if (sessionId !== undefined && sessionId !== null && typeof sessionId !== "string") {
    throw new ProtocolError("bad_request", "participant.sessionId must be a string or null");
  }
  if (!isObject(value.tracks)) throw new ProtocolError("bad_request", "participant.tracks must be an object");
  return value as ParticipantJson;
}

/** The presence server. Attach it to an HTTP server with {@link handleUpgrade}. */
export class PresenceServer {
  readonly #wss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
  readonly #rooms = new Map<string, Map<string, Member>>();
  readonly #connections = new Set<Connection>();
  readonly #options: PresenceOptions;
  readonly #heartbeat: NodeJS.Timeout;

  constructor(options: PresenceOptions) {
    this.#options = options;
    this.#heartbeat = setInterval(() => this.#sweep(), options.heartbeatMs ?? 2000);
    this.#heartbeat.unref();
  }

  /** Participant states in `roomId`, in join order. For tests and diagnostics. */
  participantsIn(roomId: string): ParticipantJson[] {
    return [...(this.#rooms.get(roomId)?.values() ?? [])].map((m) => m.state);
  }

  /** Number of open connections. */
  get connectionCount(): number {
    return this.#connections.size;
  }

  /** Completes a WebSocket upgrade for `/signaling`. */
  handleUpgrade(request: IncomingMessage, socket: Duplex, head: Buffer): void {
    this.#wss.handleUpgrade(request, socket, head, (ws) => {
      if (!this.#options.authorize(request)) {
        // Accept, then close with a distinct code, so clients can tell a bad
        // token from a network failure and stop retrying.
        this.#send(ws, { type: "error", code: "unauthorized", message: "missing or invalid dev token" });
        ws.close(CLOSE_UNAUTHORIZED, "unauthorized");
        return;
      }
      this.#accept(ws);
    });
  }

  /** Closes every connection and stops the heartbeat. */
  close(): Promise<void> {
    clearInterval(this.#heartbeat);
    for (const c of this.#connections) c.socket.terminate();
    return new Promise((resolve) => this.#wss.close(() => resolve()));
  }

  #accept(socket: WebSocket): void {
    const connection: Connection = { socket, alive: true, room: null, participantId: null };
    this.#connections.add(connection);
    socket.on("pong", () => {
      connection.alive = true;
    });
    socket.on("message", (data, isBinary) => {
      connection.alive = true;
      this.#onMessage(connection, data, isBinary);
    });
    socket.on("close", () => this.#drop(connection));
    socket.on("error", () => socket.terminate());
  }

  #sweep(): void {
    for (const c of this.#connections) {
      if (!c.alive) {
        this.#log(`evicting unresponsive connection${c.participantId ? ` (${c.participantId})` : ""}`);
        c.socket.terminate();
        this.#drop(c);
        continue;
      }
      c.alive = false;
      try {
        c.socket.ping();
      } catch {
        // The close handler cleans up.
      }
    }
  }

  #drop(connection: Connection): void {
    if (!this.#connections.delete(connection)) return;
    if (connection.room !== null) this.#log(`disconnect ${connection.room} ${connection.participantId}`);
    this.#removeMember(connection);
  }

  #onMessage(connection: Connection, data: RawData, isBinary: boolean): void {
    let message: Record<string, unknown>;
    try {
      if (isBinary) throw new ProtocolError("bad_request", "messages must be text");
      const parsed: unknown = JSON.parse(data.toString());
      if (!isObject(parsed) || typeof parsed.type !== "string") {
        throw new ProtocolError("bad_request", "messages must be JSON objects with a string type");
      }
      message = parsed;
    } catch (e) {
      this.#replyError(connection, undefined, e);
      return;
    }
    const id = typeof message.id === "number" || typeof message.id === "string" ? message.id : undefined;
    try {
      switch (message.type) {
        case "join":
          this.#join(connection, message);
          break;
        case "update":
          this.#update(connection, message);
          break;
        case "leave":
          if (connection.room !== null) this.#log(`leave ${connection.room} ${connection.participantId}`);
          this.#removeMember(connection);
          break;
        case "ping":
          this.#send(connection.socket, { type: "pong", ...(id === undefined ? {} : { id }) });
          return;
        default:
          throw new ProtocolError("bad_request", `unknown message type`);
      }
      if (id !== undefined) this.#send(connection.socket, { type: "ack", id });
      // The list goes out after the ack, so a client sees its join confirmed first.
      if (connection.room !== null && message.type !== "leave") this.#broadcast(connection.room);
    } catch (e) {
      this.#replyError(connection, id, e);
    }
  }

  #join(connection: Connection, message: Record<string, unknown>): void {
    if (connection.room !== null) {
      throw new ProtocolError("already_joined", "already in a room; send leave first");
    }
    if (!isValidId(message.roomId)) throw new ProtocolError("bad_request", "roomId must be a non-empty string");
    const roomId = message.roomId;
    const state = parseParticipant(message.participant);
    let room = this.#rooms.get(roomId);
    if (!room) {
      room = new Map();
      this.#rooms.set(roomId, room);
    }
    const previous = room.get(state.participantId);
    if (previous) {
      // Usually the same device reconnecting before its old socket was
      // evicted. The newer connection wins.
      room.delete(state.participantId);
      previous.connection.room = null;
      previous.connection.participantId = null;
      this.#send(previous.connection.socket, {
        type: "error",
        code: "replaced",
        message: "another connection joined with this participantId",
      });
      previous.connection.socket.close(CLOSE_REPLACED, "replaced");
      this.#log(`replace ${roomId} ${state.participantId}`);
    } else {
      this.#log(`join ${roomId} ${state.participantId}`);
    }
    room.set(state.participantId, { connection, state });
    connection.room = roomId;
    connection.participantId = state.participantId;
  }

  #update(connection: Connection, message: Record<string, unknown>): void {
    const roomId = connection.room;
    const participantId = connection.participantId;
    if (roomId === null || participantId === null) throw new ProtocolError("not_joined", "join a room first");
    const state = parseParticipant(message.participant);
    if (state.participantId !== participantId) {
      throw new ProtocolError("participant_id_changed", "update must keep the joined participantId");
    }
    this.#rooms.get(roomId)!.get(participantId)!.state = state;
  }

  #removeMember(connection: Connection): void {
    const roomId = connection.room;
    const participantId = connection.participantId;
    connection.room = null;
    connection.participantId = null;
    if (roomId === null || participantId === null) return;
    const room = this.#rooms.get(roomId);
    if (!room || room.get(participantId)?.connection !== connection) return;
    room.delete(participantId);
    if (room.size === 0) {
      this.#rooms.delete(roomId);
    } else {
      this.#broadcast(roomId);
    }
  }

  #broadcast(roomId: string): void {
    const room = this.#rooms.get(roomId);
    if (!room) return;
    const message = { type: "participants", roomId, participants: [...room.values()].map((m) => m.state) };
    for (const member of room.values()) this.#send(member.connection.socket, message);
  }

  #replyError(connection: Connection, id: string | number | undefined, e: unknown): void {
    const [code, message] = e instanceof ProtocolError
      ? [e.code, e.message]
      : e instanceof SyntaxError
      ? ["bad_request", "invalid JSON"]
      : ["internal_error", "internal error"];
    this.#send(connection.socket, { type: "error", ...(id === undefined ? {} : { id }), code, message });
  }

  #send(socket: WebSocket, message: unknown): void {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  }

  #log(message: string): void {
    this.#options.log?.(`[signaling] ${message}`);
  }
}
