// The response headers the site is served with: one definition for the site stack, which sends them from CloudFront
// (service/infra/stacks/lib/site-stack.ts), and for the local preview (tools/preview.ts), so a page that breaks under
// the deployed policy breaks under the preview too. Nothing here runs in a browser.

/**
 * The Content-Security-Policy: scripts, styles and images from the site itself only, fetches to `connectSrc` only, and
 * Trusted Types with no policy. `connectSrc` is one or more CSP sources, e.g. 'https://api.mopm.dev'.
 */
export function contentSecurityPolicy(connectSrc: string): string {
  return [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    `connect-src ${connectSrc}`,
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
    // The site writes the DOM only through createElement/setAttribute/text nodes (src/doc.ts; no HTML sink, which
    // test/no-sinks.test.ts holds), so it needs no Trusted Types policy and may create none.
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
  ].join('; ');
}

export const PERMISSIONS_POLICY = 'camera=(), microphone=(), geolocation=(), payment=(), usb=()';

/** HSTS for two years, subdomains included (730 days; the stack states it as a Duration). */
export const HSTS_MAX_AGE_SECONDS = 63_072_000;

/** Every security header a page is answered with, by lower-case name, for a CSP whose connect-src is `connectSrc`. */
export function securityHeaders(connectSrc: string): Record<string, string> {
  return {
    'content-security-policy': contentSecurityPolicy(connectSrc),
    'strict-transport-security': `max-age=${HSTS_MAX_AGE_SECONDS}; includeSubDomains`,
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
    'cross-origin-opener-policy': 'same-origin',
    'cross-origin-resource-policy': 'same-origin',
    'permissions-policy': PERMISSIONS_POLICY,
  };
}
