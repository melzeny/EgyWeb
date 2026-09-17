// Cloudflare Pages Function: POST /api/contact
// Validates the quote request form and returns JSON. Delivery is not wired up yet (see TODO below).

const MAX_LENGTHS = {
  name: 200,
  company: 200,
  email: 254,
  phone: 40,
  sector: 60,
  message: 4000,
};

function isValidEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function jsonResponse(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export async function onRequestPost({ request }) {
  let data;
  try {
    data = await request.json();
  } catch (err) {
    return jsonResponse({ ok: false, error: "Invalid request body." }, 400);
  }

  // Honeypot: real visitors never fill this hidden field in.
  if (typeof data.company_site === "string" && data.company_site.trim() !== "") {
    return jsonResponse({ ok: true }, 200);
  }

  const name = typeof data.name === "string" ? data.name.trim() : "";
  const email = typeof data.email === "string" ? data.email.trim() : "";
  const message = typeof data.message === "string" ? data.message.trim() : "";
  const company = typeof data.company === "string" ? data.company.trim() : "";
  const phone = typeof data.phone === "string" ? data.phone.trim() : "";
  const sector = typeof data.sector === "string" ? data.sector.trim() : "";

  if (!name || !email || !message) {
    return jsonResponse({ ok: false, error: "Name, email and project details are required." }, 400);
  }
  if (!isValidEmail(email)) {
    return jsonResponse({ ok: false, error: "Enter a valid email address." }, 400);
  }
  for (const [field, value] of Object.entries({ name, company, email, phone, sector, message })) {
    if (value.length > MAX_LENGTHS[field]) {
      return jsonResponse({ ok: false, error: `${field} is too long.` }, 400);
    }
  }

  // TODO(owner): wire up actual email delivery. Options include the Cloudflare Email
  // Workers "send_email" binding, or a transactional email API (e.g. Resend, Postmark,
  // SendGrid) called with a secret API key stored as a Pages environment variable.
  // For now the enquiry is only validated, not delivered — the front end falls back to
  // a mailto: link if this endpoint is unavailable, but a successful response here does
  // NOT currently send an email anywhere.

  return jsonResponse({ ok: true }, 200);
}

export async function onRequestGet() {
  return jsonResponse({ ok: false, error: "Method not allowed." }, 405);
}
