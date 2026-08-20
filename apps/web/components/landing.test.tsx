import assert from "node:assert/strict";
import { test } from "node:test";

import { cleanup, render } from "@testing-library/react";
import { JSDOM } from "jsdom";

import Landing from "./landing";

test("exposes copy results through a live region outside the button", () => {
  const dom = new JSDOM("<!doctype html><html><body></body></html>", {
    url: "https://xaq.sh/",
  });
  const previous = new Map<string, PropertyDescriptor | undefined>();

  for (const [name, value] of [
    ["window", dom.window],
    ["document", dom.window.document],
    ["navigator", dom.window.navigator],
  ] as const) {
    previous.set(name, Object.getOwnPropertyDescriptor(globalThis, name));
    Object.defineProperty(globalThis, name, { configurable: true, value });
  }

  try {
    const view = render(<Landing />);
    const button = view.getByRole("button", { name: "Copy install command" });
    const status = view.getByRole("status");

    assert.equal(button.contains(status), false);
    assert.equal(button.getAttribute("aria-describedby"), status.id);
  } finally {
    cleanup();
    dom.window.close();
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor);
      else Reflect.deleteProperty(globalThis, name);
    }
  }
});
