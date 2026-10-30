// One copy of the app per computer: copies share one pairing, so both would answer every message.
// The running copy holds a local port and greets whoever connects; a second copy sees the greeting and stops.
// The OS frees the port when the app exits, even after a crash, so there's no stale lock to clean up.
const PORT = 47613;
const GREETING = "ai-engineer";

/** True if no other copy of the app is running (and this one now holds the claim). */
export async function claimInstance(port = PORT): Promise<boolean> {
  try {
    Bun.listen({
      hostname: "127.0.0.1",
      port,
      socket: { open: (socket) => void socket.end(GREETING + "\n"), data() {} },
    });
    return true;
  } catch {
    // Something else may own the port; only a greeting proves it's another copy of the app.
    return !(await greets(port));
  }
}

function greets(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), 1000);
    const done = (result: boolean) => {
      clearTimeout(timer);
      resolve(result);
    };
    Bun.connect({
      hostname: "127.0.0.1",
      port,
      socket: {
        data(socket, data) {
          done(data.toString().startsWith(GREETING));
          socket.end();
        },
        close: () => done(false),
        connectError: () => done(false),
        error: () => done(false),
      },
    }).catch(() => done(false));
  });
}
