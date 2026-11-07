// Passkeys (WebAuthn). lib/passkeys.rb makes the options and checks each answer. This file
// only turns base64url into bytes and back, and posts the answer in a form: form#passkey-signin
// on the login page, form#passkey-create on /passkeys. data-options is the URL of the options.

const toBytes = (text) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0));
const toText = (buffer) => btoa(String.fromCharCode(...new Uint8Array(buffer ?? [])))
  .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

// The options of the server, with the bytes that the browser wants as bytes.
async function passkeyOptions(form) {
  const response = await fetch(form.dataset.options, { method: 'POST' });
  const options = await response.json();
  options.challenge = toBytes(options.challenge);
  if (options.user) options.user.id = toBytes(options.user.id);
  for (const credential of options.excludeCredentials ?? []) credential.id = toBytes(credential.id);
  return options;
}

function postAnswer(form, answer) {
  form.elements.credential.value = JSON.stringify(answer);
  form.submit();
}

// The login page asks for a passkey two ways: the autofill of the email field waits for one
// ('conditional'), and the line under the form asks at once ('optional'). A browser allows one
// request at a time, so each request cancels the one before it.
let pending;
async function signIn(form, mediation) {
  pending?.abort();
  pending = new AbortController();
  const credential = await navigator.credentials.get({ mediation, signal: pending.signal, publicKey: await passkeyOptions(form) });
  const { response } = credential;
  postAnswer(form, {
    id: credential.id,
    clientDataJSON: toText(response.clientDataJSON),
    authenticatorData: toText(response.authenticatorData),
    signature: toText(response.signature),
  });
}

// getPublicKey gives the key as DER, so the server parses no CBOR. A cancelled prompt, or a
// browser without passkeys, posts no answer, and the page says that nothing was created.
async function createPasskey(form) {
  try {
    const credential = await navigator.credentials.create({ publicKey: await passkeyOptions(form) });
    const { response } = credential;
    postAnswer(form, {
      id: credential.id,
      clientDataJSON: toText(response.clientDataJSON),
      authenticatorData: toText(response.getAuthenticatorData()),
      publicKey: toText(response.getPublicKey()),
    });
  } catch (error) {
    console.warn(error);
    postAnswer(form, null);
  }
}

// A browser without passkeys keeps the email link only, with no line. A closed prompt ends the
// request, and the autofill waits again.
const signinForm = document.getElementById('passkey-signin');
if (signinForm && window.PublicKeyCredential) {
  const autofill = async () => {
    if (await PublicKeyCredential.isConditionalMediationAvailable?.()) await signIn(signinForm, 'conditional');
  };
  const line = document.querySelector('p.passkey');
  line.hidden = false;
  line.querySelector('button').addEventListener('click', () => {
    signIn(signinForm, 'optional').catch((error) => {
      console.warn(error);
      autofill().catch((again) => console.warn(again));
    });
  });
  autofill().catch((error) => console.warn(error));
}

document.getElementById('passkey-create')?.addEventListener('submit', (event) => {
  event.preventDefault();
  createPasskey(event.target);
});
