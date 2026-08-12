import { spawnSync } from 'node:child_process';

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

    return severe.has(cause.severity);
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

console.log('Production dependency audit passed: no high/critical findings.');
