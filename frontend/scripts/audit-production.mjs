import { spawnSync } from 'node:child_process';

// npm currently reports GHSA-qwww-vcr4-c8h2 against every modern React Router
// release. The advisory only applies to React Server Components and server
// actions. This project is a client-only Vite SPA and does not ship either
// feature, so that specific finding is not reachable here. Keeping the
// exception in code means CI still fails for every other high/critical advisory
// and the exception can be removed as soon as React Router publishes a fix.
const allowedAdvisories = new Set([
  'https://github.com/advisories/GHSA-qwww-vcr4-c8h2',
]);

const result = spawnSync('npm', ['audit', '--omit=dev', '--json'], {
  encoding: 'utf8',
  shell: process.platform === 'win32',
});

if (!result.stdout) {
  console.error(result.stderr || 'npm audit did not return a report');
  process.exit(1);
}

let report;
try {
  report = JSON.parse(result.stdout);
} catch {
  console.error('npm audit returned invalid JSON');
  console.error(result.stdout);
  process.exit(1);
}

const vulnerabilities = report.vulnerabilities ?? {};
const severe = new Set(['high', 'critical']);
const memo = new Map();

function hasUnapprovedFinding(packageName, visiting = new Set()) {
  if (memo.has(packageName)) return memo.get(packageName);
  if (visiting.has(packageName)) return false;

  const vulnerability = vulnerabilities[packageName];
  if (!vulnerability || !severe.has(vulnerability.severity)) {
    memo.set(packageName, false);
    return false;
  }

  const nextVisiting = new Set(visiting).add(packageName);
  const unapproved = vulnerability.via.some((cause) => {
    if (typeof cause === 'string') {
      return hasUnapprovedFinding(cause, nextVisiting);
    }

    return severe.has(cause.severity) && !allowedAdvisories.has(cause.url);
  });

  memo.set(packageName, unapproved);
  return unapproved;
}

const blockedPackages = Object.keys(vulnerabilities).filter((packageName) =>
  hasUnapprovedFinding(packageName),
);

if (blockedPackages.length > 0) {
  console.error(
    `npm audit found unapproved high/critical vulnerabilities in: ${blockedPackages.join(', ')}`,
  );
  console.error(result.stdout);
  process.exit(1);
}

const allowedFindings = Object.values(vulnerabilities)
  .flatMap((vulnerability) => vulnerability.via)
  .filter(
    (cause) =>
      typeof cause !== 'string' &&
      severe.has(cause.severity) &&
      allowedAdvisories.has(cause.url),
  );

if (allowedFindings.length > 0) {
  console.warn(
    'Accepted GHSA-qwww-vcr4-c8h2: this client-only SPA does not use React Server Components or server actions.',
  );
}

console.log('Production dependency audit passed: no reachable high/critical findings.');
