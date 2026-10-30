import { test, expect } from "bun:test";
import { claimInstance } from "../src/instance";

test("a second copy of the app sees the first one", async () => {
  const port = 40000 + Math.floor(Math.random() * 5000);
  expect(await claimInstance(port)).toBe(true);
  expect(await claimInstance(port)).toBe(false);
});

test("a port held by some other program doesn't count as another copy", async () => {
  const port = 45000 + Math.floor(Math.random() * 2000);
  const other = Bun.listen({ hostname: "127.0.0.1", port, socket: { open: (s) => void s.end("hello\n"), data() {} } });
  expect(await claimInstance(port)).toBe(true);
  other.stop(true);
});
