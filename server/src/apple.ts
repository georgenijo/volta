import { createRemoteJWKSet, errors, jwtVerify, type JWTVerifyGetKey } from 'jose';

const issuer = 'https://appleid.apple.com';
const keysURL = new URL('https://appleid.apple.com/auth/keys');
// The app posts the token as soon as Apple returns it. A short accepted age
// bounds how long a captured token stays useful and how long used tokens
// must be remembered.
export const appleTokenMaxAgeSeconds = 600;
export const appleClockToleranceSeconds = 30;

/** The token is not a current Apple identity token for this app. */
export class AppleTokenError extends Error {}
/** Apple's signing keys could not be fetched, so nothing can be verified. */
export class AppleUnavailableError extends Error {}

// Failures that describe the token itself. Anything else, such as a timeout
// or a bad response while fetching Apple's keys, says nothing about the token.
const tokenFailures = [
  errors.JWTClaimValidationFailed, errors.JWTExpired, errors.JWTInvalid, errors.JWSInvalid,
  errors.JWSSignatureVerificationFailed, errors.JOSEAlgNotAllowed, errors.JOSENotSupported,
  errors.JWKSNoMatchingKey, errors.JWKSMultipleMatchingKeys,
];

/** Verifies Sign in with Apple identity tokens issued to one app. */
export class AppleVerifier {
  constructor(private bundleId: string, private keys: JWTVerifyGetKey = createRemoteJWKSet(keysURL, { timeoutDuration: 5000, cooldownDuration: 30_000 })) {
    if (!/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(bundleId)) throw new Error('APPLE_BUNDLE_ID must be a bundle identifier such as com.example.app');
  }
  /** Returns Apple's stable identifier for the person, scoped to the app's team. */
  async subject(token: string): Promise<string> {
    let subject: unknown;
    try {
      const { payload } = await jwtVerify(token, this.keys, {
        issuer, audience: this.bundleId, algorithms: ['RS256'],
        maxTokenAge: appleTokenMaxAgeSeconds, clockTolerance: appleClockToleranceSeconds,
      });
      subject = payload.sub;
    } catch (error) {
      // jose messages can quote claims, so neither error carries the cause.
      if (tokenFailures.some(kind => error instanceof kind)) throw new AppleTokenError();
      throw new AppleUnavailableError();
    }
    if (typeof subject !== 'string' || !subject || subject.length > 255) throw new AppleTokenError();
    return subject;
  }
}
