import { test, expect, afterAll } from "bun:test";
import { fetchWithTimeout } from "./poller";

// A server that delays past the timeout, to prove the client aborts.
const server = Bun.serve({
  port: 0,
  async fetch() {
    await new Promise((r) => setTimeout(r, 3000));
    return new Response("late");
  },
});
const base = `http://localhost:${server.port}`;
afterAll(() => server.stop(true));

test("fetchWithTimeout aborts a stalled request", async () => {
  const start = Date.now();
  let threw = false;
  try {
    await fetchWithTimeout(`${base}/slow`, 200);
  } catch {
    threw = true;
  }
  const elapsed = Date.now() - start;
  expect(threw).toBe(true);
  expect(elapsed).toBeLessThan(1500); // aborted at ~200ms, not the 3s server delay
});

test("fetchWithTimeout returns normally when the server responds in time", async () => {
  const fast = Bun.serve({ port: 0, fetch: () => new Response("ok") });
  try {
    const resp = await fetchWithTimeout(`http://localhost:${fast.port}/`, 2000);
    expect(await resp.text()).toBe("ok");
  } finally {
    fast.stop(true);
  }
});
