"use strict";
// Friend (guest) pages: accept an invite, sign in, and the room placeholder.
// The invite token travels in the URL fragment, which browsers never send to
// a server; it is posted once over the CSRF-protected API.

const mode = document.querySelector("meta[name=guest-mode]").content;

function failure(status, error) {
  if (status === 429) return "Please wait a minute before trying again.";
  if (error === "invalid_credentials") return "Username or password did not match.";
  if (error === "invalid_invite") return "This invite is invalid, used or expired. Ask for a new one.";
  if (error === "username_taken") return "That username is taken. Choose another.";
  if (error === "invalid_account_details") {
    return "Use a 3–32 character username (letters, numbers, . _ -), a name, and a password of 12+ characters.";
  }
  if (error === "guest_limit") return "This laptop has no free friend places right now.";
  if (error === "invalid_csrf") return "This page expired. Reload it and try again.";
  return "The laptop is unavailable right now. Try again later.";
}

async function freshToken(page) {
  // The prelogin cookie lasts ten minutes; refresh it right before submitting.
  const response = await fetch(page, {
    credentials: "same-origin",
    cache: "no-store",
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error("unavailable");
  const html = new DOMParser().parseFromString(await response.text(), "text/html");
  const token = html.querySelector("meta[name=csrf]")?.content ?? "";
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) throw new Error("unavailable");
  return token;
}

async function post(path, body, csrf) {
  const response = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    cache: "no-store",
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(30000),
  });
  let data = {};
  try {
    data = await response.json();
  } catch (_) {}
  if (!response.ok) throw Object.assign(new Error(data.error || "failed"), { status: response.status });
  return data;
}

function wire(formId, page, api, extra = () => ({})) {
  const form = document.getElementById(formId);
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = form.querySelector("button");
    const message = form.querySelector(".message");
    button.disabled = true;
    message.textContent = "Working…";
    try {
      const fields = Object.fromEntries(new FormData(form));
      await post(api, { ...fields, ...extra() }, await freshToken(page));
      location.replace("/remote/guest/room");
    } catch (error) {
      message.textContent = failure(error.status, error.message);
      button.disabled = false;
    }
  });
}

if (mode === "invite") {
  const token = location.hash.slice(1);
  // Remove the token from the address bar and history right away.
  history.replaceState(null, "", "/remote/guest/invite");
  document.getElementById("invite-view").hidden = false;
  if (!/^[A-Za-z0-9_-]{20,64}$/.test(token)) {
    document.querySelector("#invite .message").textContent =
      "This invite link is incomplete. Open the full link you were sent.";
    document.querySelector("#invite button").disabled = true;
  } else {
    wire("invite", "/remote/guest/invite", "/remote/guest/api/invite", () => ({ token }));
  }
} else if (mode === "signin") {
  document.getElementById("signin-view").hidden = false;
  wire("signin", "/remote/guest/signin", "/remote/guest/api/signin");
} else if (mode === "room") {
  document.getElementById("room-view").hidden = false;
  const message = document.querySelector("#room-view .message");
  let csrf = "";
  fetch("/remote/guest/api/session", { credentials: "same-origin", cache: "no-store" })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error("signed_out"))))
    .then((session) => {
      csrf = session.csrf;
      document.getElementById("room-title").textContent =
        `${session.displayName}'s listening room.`;
    })
    .catch(() => location.replace("/remote/guest/signin"));
  document.getElementById("signout").addEventListener("click", async () => {
    try {
      await post("/remote/guest/api/signout", {}, csrf);
    } catch (_) {
      message.textContent = "Signed out.";
    }
    location.replace("/remote/guest/signin");
  });
}
