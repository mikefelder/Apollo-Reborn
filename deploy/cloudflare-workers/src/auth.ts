/**
 * Authentication helpers.
 */

/**
 * Constant-time string comparison.
 *
 * `===` on strings short-circuits at the first differing character, which
 * leaks the length of the matching prefix to a timing attacker. The encoded-
 * length check below is a cheap necessary guard (you can't compare bytes of
 * different lengths constantly), but the byte loop runs the full length of
 * the expected value regardless of where (or whether) it diverges.
 */
export function timingSafeEqualStrings(a: string, b: string): boolean {
    const ea = new TextEncoder().encode(a);
    const eb = new TextEncoder().encode(b);
    if (ea.length !== eb.length) return false;
    let diff = 0;
    for (let i = 0; i < ea.length; i++) {
        diff |= (ea[i] as number) ^ (eb[i] as number);
    }
    return diff === 0;
}
