import assert from "node:assert/strict";
import { afterEach, beforeEach, test } from "node:test";

import { act, cleanup, fireEvent, render } from "@testing-library/react";
import { JSDOM } from "jsdom";

import { site } from "../lib/content";
import CopyCommand from "./copy-command";
import Landing from "./landing";

let dom: JSDOM;
let previous: Map<string, PropertyDescriptor | undefined>;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "https://xaq.sh/",
  });
  previous = new Map();

  for (const [name, value] of [
    ["window", dom.window],
    ["document", dom.window.document],
    ["navigator", dom.window.navigator],
  ] as const) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value });
  }
});

afterEach(() => {
  cleanup();
  dom.window.close();
  for (const [name, descriptor] of previous) {
    if (descriptor) Object.defineProperty(globalThis, name, descriptor);
    else Reflect.deleteProperty(globalThis, name);
  }
});

test("keeps the install command selectable outside the copy button", () => {
  const view = render(<Landing />);
  const command = view.getByText(site.install);
  const button = view.getByRole("button", { name: "Copy install command" });
  const status = view.getByRole("status");

  assert.equal(command.tagName, "CODE");
  assert.equal(command.textContent, site.install);
  assert.equal(button.contains(command), false);
  assert.equal(button.contains(status), false);
  assert.equal(button.getAttribute("aria-describedby"), status.id);
});

test("copies the exact command and clears the success message", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const writes: string[] = [];
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: {
      writeText: async (text: string) => {
        writes.push(text);
      },
    },
  });
  const view = render(<Landing />);

  await act(async () => {
    fireEvent.click(view.getByRole("button", { name: "Copy install command" }));
  });

  assert.deepEqual(writes, [site.install]);
  assert.equal(view.getByRole("status").textContent, "copied");
  act(() => t.mock.timers.tick(1600));
  assert.equal(view.getByRole("status").textContent, "");
});

for (const unavailable of [true, false]) {
  test(`keeps manual copy instructions visible when the clipboard is ${unavailable ? "unavailable" : "denied"}`, async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout"] });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: unavailable
        ? undefined
        : {
            writeText: async () => {
              throw new Error("permission denied");
            },
          },
    });
    const view = render(<Landing />);

    await act(async () => {
      fireEvent.click(view.getByRole("button", { name: "Copy install command" }));
    });

    const status = view.getByRole("status");
    assert.match(status.textContent ?? "", /Select the command to copy it manually/);
    act(() => t.mock.timers.tick(10_000));
    assert.match(status.textContent ?? "", /Select the command to copy it manually/);

    Object.defineProperty(navigator, "clipboard", {
      value: { writeText: async () => {} },
    });
    await act(async () => {
      fireEvent.click(view.getByRole("button", { name: "Copy install command" }));
    });
    assert.equal(status.textContent, "copied");
  });
}

test("a late clipboard result does not replace a newer attempt's status", async () => {
  let finishFirst!: () => void;
  let attempts = 0;
  Object.defineProperty(navigator, "clipboard", {
    value: {
      writeText: () => {
        attempts += 1;
        return attempts === 1
          ? new Promise<void>((resolve) => {
              finishFirst = resolve;
            })
          : Promise.reject(new Error("permission denied"));
      },
    },
  });
  const view = render(<Landing />);
  const button = view.getByRole("button", { name: "Copy install command" });

  await act(async () => {
    fireEvent.click(button);
  });
  await act(async () => {
    fireEvent.click(button);
  });
  assert.match(view.getByRole("status").textContent ?? "", /Couldn't copy/);

  await act(async () => {
    finishFirst();
  });
  assert.match(view.getByRole("status").textContent ?? "", /Couldn't copy/);
});

test("each copy button describes its own status", () => {
  const view = render(
    <>
      <CopyCommand command="first" />
      <CopyCommand command="second" />
    </>,
  );
  const buttons = view.getAllByRole("button", { name: "Copy install command" });
  const statuses = view.getAllByRole("status");

  assert.notEqual(statuses[0].id, statuses[1].id);
  assert.equal(buttons[0].getAttribute("aria-describedby"), statuses[0].id);
  assert.equal(buttons[1].getAttribute("aria-describedby"), statuses[1].id);
});
