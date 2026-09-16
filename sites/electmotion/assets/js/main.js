(() => {
  const root = document.documentElement;
  root.classList.remove("no-js");

  // Header: solid background after scrolling, mobile menu toggle
  const header = document.querySelector(".site-header");
  const toggle = document.querySelector(".nav-toggle");
  if (header) {
    const onScroll = () => header.classList.toggle("is-solid", window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
  }
  if (header && toggle) {
    const setOpen = (open) => {
      header.classList.toggle("is-open", open);
      toggle.setAttribute("aria-expanded", String(open));
      document.body.style.overflow = open ? "hidden" : "";
    };
    toggle.addEventListener("click", () => setOpen(!header.classList.contains("is-open")));
    header.querySelectorAll(".nav a").forEach((a) => a.addEventListener("click", () => setOpen(false)));
    document.addEventListener("keydown", (e) => { if (e.key === "Escape") setOpen(false); });
  }

  // Reveal on scroll
  const revealables = document.querySelectorAll(".reveal");
  if ("IntersectionObserver" in window) {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          io.unobserve(entry.target);
        }
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    revealables.forEach((el) => io.observe(el));
  } else {
    revealables.forEach((el) => el.classList.add("is-visible"));
  }

  // Footer year
  document.querySelectorAll("[data-year]").forEach((el) => { el.textContent = new Date().getFullYear(); });

  // Catalog filter (products page)
  const chips = document.querySelectorAll(".chip[data-filter]");
  const items = document.querySelectorAll(".cat-item[data-sector]");
  const applyFilter = (value) => {
    chips.forEach((c) => c.setAttribute("aria-pressed", String(c.dataset.filter === value)));
    items.forEach((item) => {
      item.hidden = value !== "all" && !item.dataset.sector.split(" ").includes(value);
    });
  };
  chips.forEach((chip) => chip.addEventListener("click", () => applyFilter(chip.dataset.filter)));

  // Contact form: submits to the Pages Function; falls back to the mail client if that fails
  const form = document.querySelector("#quote-form");
  if (form) {
    const openMailto = (data) => {
      const subject = `Quote request — ${data.get("company") || data.get("name")}`;
      const body = [
        `Name: ${data.get("name")}`,
        `Company: ${data.get("company") || "-"}`,
        `Email: ${data.get("email")}`,
        `Phone: ${data.get("phone") || "-"}`,
        `Sector: ${data.get("sector")}`,
        "",
        data.get("message"),
      ].join("\n");
      const to = form.dataset.mailto;
      window.location.href = `mailto:${to}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
    };

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const status = form.querySelector(".form-status");
      if (!form.checkValidity()) {
        form.reportValidity();
        return;
      }
      const data = new FormData(form);
      const submitBtn = form.querySelector('button[type="submit"]');
      if (submitBtn) submitBtn.disabled = true;
      if (status) status.textContent = "Sending your enquiry…";

      try {
        const payload = Object.fromEntries(data.entries());
        const res = await fetch("/api/contact", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(payload),
        });
        if (!res.ok) throw new Error("Request failed");
        const result = await res.json();
        if (!result.ok) throw new Error(result.error || "Request failed");
        if (status) status.textContent = "Thank you — your enquiry has been received. We'll be in touch shortly.";
        form.reset();
      } catch (err) {
        openMailto(data);
        if (status) status.textContent = "Your email app should open with the enquiry ready to send.";
      } finally {
        if (submitBtn) submitBtn.disabled = false;
      }
    });
  }
})();
