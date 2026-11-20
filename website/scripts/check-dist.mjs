// Checks the built site in dist/: every internal link and asset sits under the
// base path and points at a file that exists, and every fragment names an id on
// its target page. External URLs are not fetched. Run after `astro build`.
import { readdir, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import config from '../astro.config.mjs';

const dist = path.resolve(import.meta.dirname, '../dist');
const base = (config.base ?? '/').replace(/\/?$/, '/');
const pages = (await readdir(dist, { recursive: true })).filter((file) =>
	file.endsWith('.html'),
);

const ids = new Map();
const html = new Map();
for (const page of pages) {
	const text = await readFile(path.join(dist, page), 'utf8');
	html.set(page, text);
	ids.set(
		page,
		new Set([...text.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1])),
	);
}

// Map a URL path under the base to the built file that serves it.
function fileFor(urlPath) {
	const rel = decodeURIComponent(urlPath.slice(base.length));
	if (rel === '' || rel.endsWith('/')) return path.join(rel, 'index.html');
	if (existsSync(path.join(dist, rel))) return rel;
	return `${rel}.html`;
}

const errors = [];
for (const [page, text] of html) {
	for (const [, attr, value] of text.matchAll(/\s(href|src)="([^"]*)"/g)) {
		if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith('//')) continue;
		const [location, fragment] = value.split('#');
		let target = page;
		if (location) {
			if (!location.startsWith(base) && `${location}/` !== base) {
				errors.push(
					`${page}: ${attr}="${value}" is outside the base path ${base}`,
				);
				continue;
			}
			target = fileFor(location.split('?')[0]);
			if (!existsSync(path.join(dist, target))) {
				errors.push(`${page}: ${attr}="${value}" has no file in dist/`);
				continue;
			}
		}
		if (fragment && !ids.get(target)?.has(decodeURIComponent(fragment))) {
			errors.push(`${page}: ${attr}="${value}" names no id on ${target}`);
		}
	}
}

for (const error of errors) console.error(`check-dist: ${error}`);
if (errors.length) process.exit(1);
console.log(
	`check-dist: ${pages.length} pages, links and assets resolve under ${base}`,
);
