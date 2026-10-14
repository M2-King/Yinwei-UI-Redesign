"use strict";
async function freshLoginToken() {
  // A tab can outlive its five-minute prelogin cookie, or another tab can
  // replace that cookie. Refresh both the same-origin cookie and token just
  // before submitting; keep the gateway's CSRF/Origin checks intact.
  const response = await fetch('/remote/signin', {
    credentials: 'same-origin', cache: 'no-store',
    signal: AbortSignal.timeout(10000),
  });
  if (!response.ok) throw new Error('login_connection_unavailable');
  const page = new DOMParser().parseFromString(await response.text(), 'text/html');
  const token = page.querySelector('meta[name=csrf]')?.content;
  if (!/^[A-Za-z0-9_-]{43}$/.test(token ?? '')) {
    throw new Error('login_connection_unavailable');
  }
  document.querySelector('meta[name=csrf]').content = token;
  return token;
}

function loginFailure(status, error) {
  if (status === 429) return 'Please wait before trying again.';
  if (status === 401 && error === 'invalid_credentials') {
    return 'The account or password did not match. Please try again.';
  }
  if (error === 'invalid_csrf') {
    return 'Your sign-in page expired or cookies were blocked. Reload this page and try again.';
  }
  if (error === 'origin_changed') {
    return 'The laptop connection changed. Open Yinwei again from your fixed bookmark.';
  }
  return 'Laptop connection unavailable. Open Yinwei again from your fixed bookmark.';
}

document.querySelector("#signin").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget,
    button = form.querySelector("button");
  const message = document.querySelector("#message");
  button.disabled = true;
  message.textContent = "Signing in…";
  try {
    const submit = async () => fetch("/remote/api/auth/signin", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": await freshLoginToken(),
      },
      body: JSON.stringify({
        username: form.elements.username.value.trim(),
        password: form.elements.password.value,
      }),
      signal: AbortSignal.timeout(65000),
    });
    let response = await submit();
    let result = await response.json().catch(() => ({}));
    // Retry only a rejected prelogin check, which has not tested credentials
    // or consumed an authentication attempt. Never repeat a password failure.
    if (response.status === 403 && result.error === 'invalid_csrf') {
      response = await submit();
      result = await response.json().catch(() => ({}));
    }
    if (!response.ok) {
      message.textContent = loginFailure(response.status, result.error);
      return;
    }
    if (result.signedIn !== true) throw new Error('invalid_login_response');
    location.assign("/remote/app");
  } catch (_) {
    message.textContent =
      "Laptop connection unavailable. Try again when it is online.";
  } finally {
    form.elements.password.value = "";
    button.disabled = false;
  }
});
