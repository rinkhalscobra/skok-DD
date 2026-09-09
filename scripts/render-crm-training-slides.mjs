import { chromium } from 'playwright';
import { readFile, mkdir } from 'node:fs/promises';
import path from 'node:path';

const projectRoot = process.cwd();
const slides = JSON.parse(
  await readFile(path.join(projectRoot, 'docs/crm-training/slides.json'), 'utf8'),
);
const capturesDirectory = path.join(projectRoot, 'docs/crm-training/assets/captures');
const outputDirectory = path.join(projectRoot, 'docs/crm-training/assets/slides');

await mkdir(outputDirectory, { recursive: true });

const captureData = new Map();
for (const capture of new Set(slides.flatMap((slide) => slide.captures))) {
  const data = await readFile(path.join(capturesDirectory, `${capture}.png`));
  captureData.set(capture, `data:image/png;base64,${data.toString('base64')}`);
}

const browser = await chromium.launch({
  executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
  headless: true,
});
const page = await browser.newPage({
  viewport: { width: 1920, height: 1080 },
  deviceScaleFactor: 1,
});

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function imageGrid(slide) {
  const images = slide.captures.map((capture) => {
    const source = captureData.get(capture);
    return `<div class="shot"><img src="${source}" alt="" /></div>`;
  });
  return `<div class="shots shots-${Math.min(images.length, 4)}">${images.join('')}</div>`;
}

function slideHtml(slide, index) {
  const isTitle = index === 0;
  const titleSize = isTitle ? 54 : slide.title.length > 50 ? 40 : 47;
  const bullets = slide.bullets
    .map((bullet) => `<li><span class="check">✓</span><span>${escapeHtml(bullet)}</span></li>`)
    .join('');

  return `<!doctype html>
  <html lang="en">
    <head>
      <meta charset="utf-8" />
      <style>
        * { box-sizing: border-box; }
        html, body { width: 1920px; height: 1080px; margin: 0; overflow: hidden; }
        body {
          font-family: Inter, "Segoe UI", Arial, sans-serif;
          color: #eefcf7;
          background:
            radial-gradient(circle at 9% 8%, rgba(33, 194, 137, .20), transparent 30%),
            radial-gradient(circle at 88% 88%, rgba(13, 114, 82, .25), transparent 34%),
            linear-gradient(135deg, #07130f 0%, #0b1d18 48%, #07110f 100%);
        }
        .deck { position: relative; width: 100%; height: 100%; padding: 52px 64px 42px; }
        .deck::before {
          content: ""; position: absolute; inset: 24px; border: 1px solid rgba(132, 231, 195, .16);
          border-radius: 34px; pointer-events: none;
        }
        .top { height: 235px; display: flex; align-items: flex-start; justify-content: space-between; gap: 48px; }
        .heading { max-width: 1370px; }
        .kicker { color: #72e0b8; font-size: 20px; font-weight: 800; letter-spacing: .24em; text-transform: uppercase; }
        h1 { margin: 18px 0 8px; font-family: Georgia, "Times New Roman", serif; font-size: ${titleSize}px; line-height: 1.06; letter-spacing: -.025em; }
        .subtitle { margin: 0; color: #b7cbc4; font-size: 23px; line-height: 1.42; max-width: 1400px; }
        .number {
          width: 76px; height: 76px; flex: 0 0 auto; display: grid; place-items: center;
          border-radius: 24px; border: 1px solid rgba(114, 224, 184, .28);
          background: rgba(20, 61, 48, .62); color: #8cf0ca; font-size: 25px; font-weight: 800;
        }
        .content { height: 730px; display: grid; grid-template-columns: 1.55fr .85fr; gap: 30px; }
        .shots { display: grid; gap: 15px; min-width: 0; min-height: 0; }
        .shots-1 { grid-template-columns: 1fr; }
        .shots-2 { grid-template-rows: 1fr 1fr; }
        .shots-3, .shots-4 { grid-template-columns: 1fr 1fr; grid-template-rows: 1fr 1fr; }
        .shots-3 .shot:first-child { grid-row: 1 / span 2; }
        .shot {
          min-width: 0; min-height: 0; overflow: hidden; border-radius: 23px;
          border: 1px solid rgba(151, 234, 204, .24); background: #f4faf8;
          box-shadow: 0 28px 75px rgba(0, 0, 0, .34);
        }
        .shot img { width: 100%; height: 100%; display: block; object-fit: cover; object-position: center top; }
        .notes {
          align-self: stretch; padding: 34px 34px 30px; border-radius: 25px;
          border: 1px solid rgba(151, 234, 204, .18); background: rgba(9, 31, 24, .84);
          box-shadow: inset 0 1px rgba(255,255,255,.04); display: flex; flex-direction: column;
        }
        .notes-label { color: #72e0b8; font-size: 16px; font-weight: 800; letter-spacing: .20em; text-transform: uppercase; }
        ul { margin: 26px 0 0; padding: 0; list-style: none; display: grid; gap: 23px; }
        li { display: grid; grid-template-columns: 29px 1fr; gap: 13px; color: #e8f5f0; font-size: 22px; line-height: 1.42; }
        .check { color: #75e7bd; font-weight: 900; }
        .scope { margin-top: auto; padding-top: 26px; color: #8da69d; font-size: 16px; line-height: 1.4; }
        .footer { position: absolute; left: 66px; right: 66px; bottom: 17px; display: flex; justify-content: space-between; color: #739087; font-size: 14px; letter-spacing: .08em; text-transform: uppercase; }
        .title-slide .content { grid-template-columns: 1.18fr .82fr; }
        .title-slide .shot img { object-fit: contain; object-position: center; filter: saturate(.75) brightness(.72); }
        .title-slide .notes { background: linear-gradient(150deg, rgba(16, 65, 48, .94), rgba(7, 27, 21, .94)); }
      </style>
    </head>
    <body>
      <main class="deck ${isTitle ? 'title-slide' : ''}">
        <header class="top">
          <div class="heading">
            <div class="kicker">${escapeHtml(slide.kicker)}</div>
            <h1>${escapeHtml(slide.title)}</h1>
            <p class="subtitle">${escapeHtml(slide.subtitle)}</p>
          </div>
          <div class="number">${String(index + 1).padStart(2, '0')}</div>
        </header>
        <section class="content">
          ${imageGrid(slide)}
          <aside class="notes">
            <div class="notes-label">What to know</div>
            <ul>${bullets}</ul>
            <p class="scope">Privacy-sanitized training capture • No customer action submitted</p>
          </aside>
        </section>
        <footer class="footer"><span>SKOK Bank CRM Training</span><span>CRM ↔ Supabase ↔ Customer Dashboard</span></footer>
      </main>
    </body>
  </html>`;
}

try {
  for (let index = 0; index < slides.length; index += 1) {
    await page.setContent(slideHtml(slides[index], index), { waitUntil: 'load' });
    await page.waitForTimeout(150);
    const output = path.join(outputDirectory, `slide-${String(index + 1).padStart(2, '0')}.png`);
    await page.screenshot({ path: output, animations: 'disabled' });
  }
  console.log(`Rendered ${slides.length} presentation slides in ${outputDirectory}`);
} finally {
  await browser.close();
}
