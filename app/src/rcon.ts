import { Socket } from "node:net";

/** Minimal Source RCON client (what Factorio speaks). One command at a time, in order. */
export class Rcon {
  private socket: Socket | null = null;
  private buffer = Buffer.alloc(0);
  private nextId = 1;
  private authId = -2;
  private waiting = new Map<number, { resolve: (body: string) => void; reject: (e: Error) => void }>();
  private queue: Promise<unknown> = Promise.resolve();

  constructor(
    private readonly options: { host: string; port: number; password: string; timeoutMs?: number },
  ) {}

  get connected() {
    return this.socket !== null && !this.socket.destroyed;
  }

  async connect(): Promise<void> {
    if (this.connected) return;
    const socket = new Socket();
    this.socket = socket;
    this.buffer = Buffer.alloc(0);
    socket.on("data", (chunk: Buffer) => this.receive(chunk));
    socket.on("close", () => this.fail(new Error("Factorio closed the RCON connection")));
    socket.on("error", (error) => this.fail(error));
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", resolve);
      socket.once("error", reject);
      socket.connect(this.options.port, this.options.host);
    });
    try {
      this.authId = this.nextId;
      await this.send(3, this.options.password);
    } catch (error) {
      this.close();
      throw error;
    }
  }

  /** Run a console command and return its rcon.print output. */
  command(text: string): Promise<string> {
    const run = this.queue.then(() => this.send(2, text));
    this.queue = run.catch(() => undefined);
    return run;
  }

  close() {
    this.socket?.destroy();
    this.fail(new Error("RCON closed"));
  }

  private send(type: number, body: string): Promise<string> {
    const socket = this.socket;
    if (!socket || socket.destroyed) return Promise.reject(new Error("RCON is not connected"));
    const id = this.nextId++;
    const payload = Buffer.from(body, "utf8");
    const packet = Buffer.alloc(14 + payload.length);
    packet.writeInt32LE(10 + payload.length, 0);
    packet.writeInt32LE(id, 4);
    packet.writeInt32LE(type, 8);
    payload.copy(packet, 12);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.waiting.delete(id);
        reject(new Error("Factorio didn't answer in time"));
      }, this.options.timeoutMs ?? 10000);
      this.waiting.set(id, {
        resolve: (value) => (clearTimeout(timer), resolve(value)),
        reject: (error) => (clearTimeout(timer), reject(error)),
      });
      socket.write(packet);
    });
  }

  private receive(chunk: Buffer) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 4) {
      const size = this.buffer.readInt32LE(0);
      if (this.buffer.length < size + 4) return;
      const id = this.buffer.readInt32LE(4);
      const type = this.buffer.readInt32LE(8);
      const body = this.buffer.toString("utf8", 12, size + 2);
      this.buffer = this.buffer.subarray(size + 4);
      if (id === -1) {
        this.fail(new Error("Factorio rejected the RCON password"));
        return;
      }
      // While authenticating, only the auth response (type 2) counts.
      if (id === this.authId && type !== 2) continue;
      const waiter = this.waiting.get(id);
      this.waiting.delete(id);
      waiter?.resolve(body);
    }
  }

  private fail(error: Error) {
    for (const waiter of this.waiting.values()) waiter.reject(error);
    this.waiting.clear();
    this.socket = null;
  }
}
