// Outbound links. Every link that leaves the site is defined here, so a moved
// doc or a renamed repository is a one-line change.

export const GITHUB_URL = 'https://github.com/valtteriluomapareto/silta';
const blob = (path: string) => `${GITHUB_URL}/blob/main/${path}`;

export const INSTALL_URL = blob('README.md#install');
export const DATA_URL = blob('README.md#how-it-fits-together');
export const DOCS_URL = blob('docs/README.md');
export const GETTING_STARTED_URL = blob('docs/getting-started.md');
export const HUMAN_GUIDE_URL = blob('docs/human-guide.md');
export const SPEC_URL = blob('docs/spec.md');
export const CONTRIBUTING_URL = blob('CONTRIBUTING.md');
export const LICENSE_URL = blob('LICENSE');

// What the Copy button in the closing section puts on the clipboard: the
// install steps from the README, joined into one line.
export const INSTALL_COMMAND = `git clone ${GITHUB_URL}.git && cd silta && scripts/install-dev.sh`;
