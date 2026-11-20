// Prefix a site-relative path with the configured base path (`/silta/` on
// GitHub Pages), so links and assets work under a project site.
export function withBase(path = ''): string {
	const base = import.meta.env.BASE_URL.replace(/\/?$/, '/');
	return base + path.replace(/^\//, '');
}
