import { test, expect } from "bun:test";
import { readRcon, writeRcon } from "../src/setup";
import { validate } from "../src/tools";

test("RCON settings are added to Factorio's config.ini without touching other lines", () => {
  const ini = "[path]\r\nread-data=__PATH__executable__/../../data\r\n\r\n[other]\r\n; local-rcon-socket=\r\ncheck-updates=true\r\n";
  const out = writeRcon(ini, "127.0.0.1:27015", "secret");
  expect(out).toContain("local-rcon-socket=127.0.0.1:27015\r\n");
  expect(out).toContain("[other]\r\nlocal-rcon-password=secret");
  expect(out).toContain("check-updates=true");
  expect(readRcon(out)).toEqual({ host: "127.0.0.1", port: 27015, password: "secret" });
  expect(readRcon("[other]\n; local-rcon-socket=1.2.3.4:1\n")).toBeNull();
});

test("tool input validation", () => {
  expect(validate("walk_to", { x: 1, y: 2 })).toBeNull();
  expect(validate("walk_to", { x: 1 })).toContain("Missing y");
  expect(validate("mine", { name: "iron-ore", count: 1.5 })).toContain("whole number");
  expect(validate("observe", { radius: 500 })).toContain("too large");
  expect(validate("observe", { other: 1 })).toContain("Unknown argument");
  expect(validate("nope", {})).toContain("Unknown tool");
});
