// CRM 导入后的 UI 冒烟验收：登录 → 各业务页 → 输出 DOM 结构事实（菜单/表格列/行数/错误）
// 用法: PW_CHROMIUM=<chromium路径> node scripts/crm-import/ui-acceptance.mjs [菜单名...]
import { chromium } from '@playwright/test';
import path from 'node:path';

const BASE = process.env.NOCOBASE_URL || 'http://localhost:13000';
const OUT = path.resolve('storage/backups/crm-import-work');
const pages = process.argv.slice(2).length ? process.argv.slice(2) : ['Leads', 'Customers', 'Opportunities', 'Orders', 'Products'];

const browser = await chromium.launch({ executablePath: process.env.PW_CHROMIUM || undefined });
const page = await browser.newPage({ viewport: { width: 1600, height: 900 } });
const errors = [];
page.on('pageerror', (e) => errors.push('pageerror: ' + e.message.slice(0, 160)));
page.on('console', (m) => m.type() === 'error' && errors.push('console: ' + m.text().slice(0, 160)));

await page.goto(BASE + '/signin');
await page.getByRole('textbox', { name: 'Username/Email' }).fill('admin@nocobase.com');
await page.getByRole('textbox', { name: 'Password' }).fill('admin123');
await page.getByRole('button', { name: /Sign in/ }).click();
await page.waitForURL((u) => !String(u).includes('signin'), { timeout: 20000 });
await page.waitForTimeout(4000);

// 左侧菜单事实
const menus = await page.locator('aside a, nav a, [class*=sider] a').allInnerTexts();
console.log('== 左侧菜单 ==\n' + menus.filter(Boolean).join(' | '));
console.log('== 当前 URL ==', page.url());
await page.screenshot({ path: path.join(OUT, 'ui-home.png'), fullPage: false });

for (const title of pages) {
  const link = page.getByRole('link', { name: new RegExp(title) }).first();
  if (!(await link.count())) { console.log(`\n[${title}] 未找到菜单链接`); continue; }
  await link.click();
  await page.waitForTimeout(4000);
  const headers = await page.locator('th').allInnerTexts();
  const rows = await page.locator('tbody tr').count();
  const charts = await page.locator('[class*=chart], canvas').count();
  console.log(`\n[${title}] url=${page.url()}`);
  console.log(`  表头(${headers.length}): ${headers.filter(Boolean).slice(0, 12).join(' / ')}`);
  console.log(`  数据行: ${rows}  图表元素: ${charts}`);
  await page.screenshot({ path: path.join(OUT, `ui-${title.toLowerCase()}.png`) });
}
console.log('\n== 页面错误去重 (' + errors.length + ' 条) ==');
console.log([...new Set(errors)].slice(0, 12).join('\n') || '(无)');
await browser.close();
