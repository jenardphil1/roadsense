# 🎨 Coolex Shop — UI Aesthetic Prompt

> Use this prompt when asking an AI to build new pages that should match the look and feel of the **Profile** and **GCash Payment** pages in the Coolex Shop.

---

## Prompt

Build a clean, modern, and visually refreshing UI page using the following design system. The goal is a design that feels **premium but minimal** — easy on the eyes, airy, and confident without being flashy.

---

### 🎨 Color Palette

- **Background:** `#f8f9fa` (light off-white, never pure white)
- **Primary Accent:** `#dc3545` (red) — used for CTAs, badges, icons, highlights
- **Primary Hover:** `#bb2d3b`
- **Text Primary:** `#1a1a1a`
- **Text Muted:** `#6c757d`
- **Card Background:** `white` with `rgba(0,0,0,0.05)` border
- **Section Dividers / Subtle Fills:** `rgba(0,0,0,0.03)` or `rgba(255,255,255,0.5)`
- **Warning Accent:** `#ff9800` (orange, used sparingly for alerts)

---

### 🔤 Typography

- **Font:** `Outfit` from Google Fonts — weights 300, 400, 600, 800
  - Import: `@import url('https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;600;800&display=swap');`
- **Headings:** `font-weight: 800; letter-spacing: -0.5px;`
- **Section Labels / Eyebrows:** `font-size: 0.7rem; text-transform: uppercase; letter-spacing: 2px; color: #6c757d; opacity: 0.5;`
- **Small metadata text:** `font-size: 0.65rem; text-transform: uppercase; letter-spacing: 1px;`
- **Page Title:** `font-size: clamp(1.1rem, 3vw, 1.6rem); font-weight: 900; line-height: 1.1;`

---

### 🃏 Card Component — `.glass-card`

```css
.glass-card {
    background: white;
    border: 1px solid rgba(0, 0, 0, 0.05);
    border-radius: 1.25rem;          /* 20px — softly rounded */
    box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06);
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
}
.glass-card:hover {
    transform: translateY(-8px);
    box-shadow: 0 20px 25px -5px rgba(0,0,0,0.1), 0 10px 10px -5px rgba(0,0,0,0.04);
}
```

**Usage pattern:** Wrap each content section in a `.glass-card.p-4` or `.glass-card.p-4.p-md-5` div.

---

### 🔘 Button Component — `.modern-btn`

```css
.modern-btn {
    padding: 0.8rem 1.5rem;
    border-radius: 12px;
    font-weight: 600;
    font-size: 0.9rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
    text-decoration: none !important;
}
/* Primary (Red CTA) */
.modern-btn-primary {
    background: #dc3545;
    color: white;
    border: none;
    box-shadow: 0 4px 15px rgba(220, 53, 69, 0.4);
}
.modern-btn-primary:hover {
    background: #bb2d3b;
    transform: translateY(-2px);
    box-shadow: 0 8px 25px rgba(220, 53, 69, 0.5);
}
/* Small variant */
.modern-btn-sm {
    padding: 0.3rem 1rem;
    font-size: 0.7rem;
    border-radius: 8px;
    min-height: 38px;
}
/* Ghost / Outline variant */
.modern-btn-ghost {
    background: transparent;
    border: 2px solid #e53935;
    color: #e53935;
}
```

---

### 📐 Layout Pattern

- Use **Bootstrap 5 grid** (`row`, `col-lg-4`, `col-lg-8`).
- **Left column (col-lg-4):** Stacked info cards (account details, addresses, stats).
- **Right column (col-lg-8):** The main content area (order history, forms, actions).
- **Page header:** A flex row with a **colored avatar circle** (initials, red bg + shadow) on the left, page title + subtitle below it, and action buttons flush to the right.
- **Container:** `container py-5` — generous vertical breathing room.
- **Card gap:** `g-4` between grid items.

---

### 🧩 UI Patterns & Micro-Details

#### Avatar / User Badge
```html
<div style="width:54px; height:54px; background:#dc3545; border-radius:50%;
            box-shadow: 0 8px 20px rgba(229,57,53,0.25);
            display:flex; align-items:center; justify-content:center;">
    <span style="font-size:1.4rem; font-weight:800; color:white;">J</span>
</div>
```

#### Section Label (Eyebrow)
```html
<h6 style="font-size:0.7rem; text-transform:uppercase; letter-spacing:2px;
           color:#6c757d; opacity:0.5; font-weight:700; margin-bottom:0.75rem;">
    Account Info
</h6>
```

#### Field Display (Label + Value)
```html
<div style="margin-bottom:0.75rem;">
    <div style="font-size:0.65rem; text-transform:uppercase; letter-spacing:1px;
                color:#6c757d; font-weight:700; margin-bottom:2px;">Email</div>
    <div style="font-weight:700;">user@example.com</div>
</div>
```

#### Numbered Step Guide
```html
<div style="display:flex; gap:12px; align-items:flex-start; margin-bottom:12px;">
    <div style="width:28px; height:28px; background:#dc3545; color:white;
                border-radius:50%; display:flex; align-items:center;
                justify-content:center; font-weight:700; font-size:0.75rem; flex-shrink:0;">1</div>
    <div style="font-size:0.9rem; padding-top:4px;">Open your <strong>GCash app</strong> and scan the QR code.</div>
</div>
```

#### Accordion / Collapsible Row (Order History style)
- Each row: white bg, `border rounded-3 overflow-hidden`, `rgba(255,255,255,0.5)`
- Header button: full-width, `text-start`, no border, transparent bg, `p-4`
- Inside header: left side (order # in tiny uppercase, date in bold), right side (badge, total amount in red, chevron icon)
- Body: inner `border-top pt-3` separator, then shipping info in a `bg-light rounded-3 p-3` block

#### Alert / Banner (Warning style)
```css
background: linear-gradient(135deg, rgba(255,152,0,0.12), rgba(255,152,0,0.06));
border: 1px solid rgba(255,152,0,0.4);
border-radius: 14px;
padding: 22px 26px;
```

#### Status Badges
```html
<!-- Paid/Completed -->
<span class="badge bg-success rounded-pill px-3 py-2 fw-bold">✓ COMPLETED</span>
<!-- Pending -->
<span class="badge bg-warning text-dark rounded-pill px-3 py-2 fw-bold">⏳ PENDING</span>
<!-- Cancelled -->
<span class="badge bg-danger rounded-pill px-3 py-2 fw-bold">✕ CANCELLED</span>
```

---

### ✅ Design Rules (Always Follow)

1. **Never use flat, heavy borders** — use `rgba(0,0,0,0.05)` or `0.08` at most.
2. **White cards on `#f8f9fa` background** — the contrast is subtle and intentional.
3. **Red is for action only** — CTAs, active states, pricing, important badges.
4. **Generous padding** — `p-4` minimum on cards. Mobile: `p-3`. Large screens: `p-md-5`.
5. **Everything rounded** — `border-radius: 12px` minimum. Cards: `1.25rem`. Circles: `50%`.
6. **Transitions on everything interactive**: `all 0.3s cubic-bezier(0.4, 0, 0.2, 1)`.
7. **Empty states** — use a large emoji, a bold heading, a muted subtitle, and a CTA button.
8. **Mobile first**: use `clamp()` for font sizes, `flex-wrap: wrap`, and `gap` instead of margins for spacing.
9. **Scrollbar styling**: thin, with red thumb on hover.
10. **No drop shadows on text** — shadows go on cards and buttons only.

---

### 📦 Dependencies

- Bootstrap 5 (CSS + JS) — for grid, modals, collapse, badges
- Bootstrap 4 compat if using `data-toggle`/`data-target` (older CI3 setups)
- Font Awesome 5 Free — for icons (`fa-check-circle`, `fa-map-marker-alt`, etc.)
- Google Fonts: Outfit

---

> **Tone:** Clean. Professional. Breathable. Think "premium card shop" — not "flashy marketplace". Every detail should feel intentional and calm, not loud.
