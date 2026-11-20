// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// GitHub Pages serves a project site at https://<owner>.github.io/<repo>/.
// Both parts come from GITHUB_REPOSITORY in Actions, so a renamed repository
// deploys to the right place. Local builds use the fallback. Outbound links are
// in src/consts.ts.
const FALLBACK_REPOSITORY = 'valtteriluomapareto/silta';
const repository = process.env.GITHUB_REPOSITORY || FALLBACK_REPOSITORY;
const parts = repository.split('/');
if (parts.length !== 2 || !parts[0] || !parts[1]) {
	throw new Error(
		`Invalid GITHUB_REPOSITORY value: "${repository}". Expected "owner/repo".`,
	);
}
const [owner, repo] = parts;

// https://astro.build/config
export default defineConfig({
	site: `https://${owner.toLowerCase()}.github.io`,
	base: `/${repo}`,
	trailingSlash: 'ignore',
	// The landing page is the only indexable page; list it once, with its slash.
	integrations: [sitemap({ filter: (page) => page.endsWith('/') })],
});
