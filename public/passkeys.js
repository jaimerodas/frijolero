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

// The login page waits for the person to pick a passkey in the autofill of the email field.
// A browser without the autofill keeps the email link only.
async function signIn(form) {
  if (!(await window.PublicKeyCredential?.isConditionalMediationAvailable?.())) return;
  const credential = await navigator.credentials.get({ mediation: 'conditional', publicKey: await passkeyOptions(form) });
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

const signinForm = document.getElementById('passkey-signin');
// A closed prompt ends the wait. The email link still works, and a reload offers the passkeys again.
if (signinForm) signIn(signinForm).catch((error) => console.warn(error));

document.getElementById('passkey-create')?.addEventListener('submit', (event) => {
  event.preventDefault();
  createPasskey(event.target);
});
