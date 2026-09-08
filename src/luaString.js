/**
 * Encodes a string as a Lua long string literal (`[[...]]`),
 * choosing enough `=` signs so the delimiter does not appear inside the value.
 *
 * @param {string} value - The string to encode
 * @param {number} [minEquals=0] - Minimum number of `=` signs to use
 * @returns {string}
 */
function toLuaLongString(value, minEquals = 0) {
  let equals = "=".repeat(minEquals);
  while (value.includes(`]${equals}]`)) {
    equals += "=";
  }
  return `[${equals}[${value}]${equals}]`;
}

module.exports = { toLuaLongString };
