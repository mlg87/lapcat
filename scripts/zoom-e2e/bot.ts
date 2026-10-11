// Second participant for `lapcat-dev zoom-e2e` (#61): joins a Zoom meeting through the Meeting SDK for
// Web (component view) in headless Chromium and speaks a WAV file as its microphone.
//
//   npx tsx scripts/zoom-e2e/bot.ts --meeting <digits> --passcode <p> --name "LapCat Bot" \
//     --audio <wav> --artifacts <dir>
//
// Env: LAPCAT_ZOOM_SDK_CLIENT_ID, LAPCAT_ZOOM_SDK_CLIENT_SECRET (a Marketplace app with the Meeting SDK
// feature). Stdout carries one JSON event per line for the harness; stderr carries logs. The bot leaves
// on a `leave` line on stdin or on SIGTERM.

import { createHmac } from "node:crypto";
import { writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { chromium, type Browser, type Page } from "playwright";

const SDK_VERSION = "6.5.0";
const AUDIO_CLICK_AFTER_MS = 10_000;
const AUDIO_GIVE_UP_AFTER_MS = 60_000;

/** The slice of the Meeting SDK's EmbeddedClient this bot calls inside the page. */
interface EmbeddedClient {
  getCurrentUser(): { audio?: string; muted?: boolean } | null;
  mute(mute: boolean): unknown;
  leaveMeeting(): Promise<unknown>;
}

interface PageConfig {
  signature: string;
  meetingNumber: string;
  password: string;
  userName: string;
}

declare global {
  interface Window {
    __lapcat?: PageConfig;
    __lapcatClient?: EmbeddedClient;
  }
}

type Event =
  | { event: "sdk-ready" }
  | { event: "joined" }
  | { event: "audio-joined"; at: number }
  | { event: "left" }
  | { event: "error"; message: string };

function emit(event: Event): void {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

function log(message: string): void {
  process.stderr.write(`[bot] ${message}\n`);
}

function fail(message: string): never {
  emit({ event: "error", message });
  process.exit(1);
}

function parseArgs(argv: string[]): Record<string, string> {
  const args: Record<string, string> = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) fail(`bad argument near ${key ?? "<end>"}`);
    args[key.slice(2)] = value;
  }
  for (const required of ["meeting", "passcode", "name", "audio", "artifacts"]) {
    if (!args[required]) fail(`missing --${required}`);
  }
  return args;
}

/** Meeting SDK JWT (https://developers.zoom.us/docs/meeting-sdk/auth/), role 0 = attendee. */
function signature(clientId: string, clientSecret: string, meeting: string): string {
  const now = Math.floor(Date.now() / 1000);
  const header = Buffer.from(JSON.stringify({ alg: "HS256", typ: "JWT" })).toString("base64url");
  const payload = Buffer.from(
    JSON.stringify({
      appKey: clientId,
      sdkKey: clientId,
      mn: meeting,
      role: 0,
      iat: now - 30,
      exp: now + 7200,
      tokenExp: now + 7200,
    }),
  ).toString("base64url");
  const mac = createHmac("sha256", clientSecret).update(`${header}.${payload}`).digest("base64url");
  return `${header}.${payload}.${mac}`;
}

const vendor = ["react", "react-dom", "react-redux", "redux", "redux-thunk", "lodash"]
  .map((name) => `<script src="https://source.zoom.us/${SDK_VERSION}/lib/vendor/${name}.min.js"></script>`)
  .join("\n");

// `window.__lapcat` is injected before load; the page reports progress through `window.__lapcatReport`.
const pageHTML = `<!doctype html>
<html><head><meta charset="UTF-8"><title>LapCat bot</title>
${vendor}
<script src="https://source.zoom.us/${SDK_VERSION}/zoom-meeting-embedded-${SDK_VERSION}.min.js"></script>
</head><body>
<div id="meetingSDKElement" style="width:960px;height:600px"></div>
<script>
(async () => {
  const config = window.__lapcat;
  try {
    const client = ZoomMtgEmbedded.createClient();
    window.__lapcatClient = client;
    await client.init({ zoomAppRoot: document.getElementById("meetingSDKElement"), language: "en-US", patchJsMedia: true });
    window.__lapcatReport({ event: "sdk-ready" });
    await client.join({
      signature: config.signature, meetingNumber: config.meetingNumber, password: config.password, userName: config.userName,
    });
    window.__lapcatReport({ event: "joined" });
  } catch (error) {
    window.__lapcatReport({ event: "error", message: "join failed: " + JSON.stringify(error, Object.getOwnPropertyNames(error ?? {})) });
  }
})();
</script>
</body></html>`;

async function audioState(page: Page): Promise<{ audio: string; muted: boolean } | null> {
  return page.evaluate(() => {
    const user = window.__lapcatClient?.getCurrentUser();
    return user ? { audio: user.audio ?? "", muted: user.muted ?? true } : null;
  });
}

/** Polls until the bot is on computer audio and unmuted; clicks the audio button and unmutes as a fallback. */
async function joinAudio(page: Page, artifacts: string): Promise<void> {
  const started = Date.now();
  let nudged = false;
  while (Date.now() - started < AUDIO_GIVE_UP_AFTER_MS) {
    const state = await audioState(page).catch(() => null);
    if (state && state.audio !== "" && !state.muted) {
      emit({ event: "audio-joined", at: Date.now() });
      return;
    }
    if (!nudged && Date.now() - started >= AUDIO_CLICK_AFTER_MS) {
      nudged = true;
      log(`audio not joined after 10 s (state ${JSON.stringify(state)}); clicking the audio button`);
      await page
        .getByRole("button", { name: /join audio|audio|unmute/i })
        .first()
        .click({ timeout: 5_000 })
        .catch((error: unknown) => log(`audio button: ${String(error)}`));
      await page
        .evaluate(() => window.__lapcatClient?.mute(false))
        .catch((error: unknown) => log(`unmute: ${String(error)}`));
    }
    await page.waitForTimeout(500);
  }
  await page.screenshot({ path: join(artifacts, "bot-screenshot.png") }).catch(() => undefined);
  const aria = await page.ariaSnapshot().catch((error: unknown) => `ariaSnapshot failed: ${String(error)}`);
  writeFileSync(join(artifacts, "bot-a11y.yaml"), aria);
  fail("audio not joined");
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const clientId = process.env.LAPCAT_ZOOM_SDK_CLIENT_ID;
  const clientSecret = process.env.LAPCAT_ZOOM_SDK_CLIENT_SECRET;
  if (!clientId || !clientSecret) fail("LAPCAT_ZOOM_SDK_CLIENT_ID and LAPCAT_ZOOM_SDK_CLIENT_SECRET must be set");

  const server = createServer((_request, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(pageHTML);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/`;

  const browser: Browser = await chromium.launch({
    channel: "chromium",
    headless: true,
    args: [
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
      `--use-file-for-fake-audio-capture=${args.audio}%noloop`,
      "--autoplay-policy=no-user-gesture-required",
    ],
  });
  let leaving = false;
  const leave = async (code: number): Promise<never> => {
    if (!leaving) {
      leaving = true;
      await browserPage
        .evaluate(() => window.__lapcatClient?.leaveMeeting())
        .catch((error: unknown) => log(`leaveMeeting: ${String(error)}`));
      emit({ event: "left" });
      await browser.close().catch(() => undefined);
      server.close();
    }
    process.exit(code);
  };

  const context = await browser.newContext();
  await context.grantPermissions(["microphone"], { origin: url });
  const browserPage = await context.newPage();
  browserPage.on("console", (message) => log(`console.${message.type()}: ${message.text()}`));
  browserPage.on("pageerror", (error) => log(`pageerror: ${error.message}`));

  const joined = new Promise<void>((resolve) => {
    void browserPage.exposeFunction("__lapcatReport", (event: Event) => {
      emit(event);
      if (event.event === "joined") resolve();
      if (event.event === "error") void leave(1);
    });
  });
  await browserPage.addInitScript((config: PageConfig) => {
    window.__lapcat = config;
  }, {
    signature: signature(clientId, clientSecret, args.meeting),
    meetingNumber: args.meeting,
    password: args.passcode,
    userName: args.name,
  });

  process.on("SIGTERM", () => void leave(0));
  createInterface({ input: process.stdin }).on("line", (line) => {
    if (line.trim() === "leave") void leave(0);
  });

  await browserPage.goto(url);
  await joined;
  await joinAudio(browserPage, args.artifacts);
}

main().catch((error: unknown) => fail(String(error)));
