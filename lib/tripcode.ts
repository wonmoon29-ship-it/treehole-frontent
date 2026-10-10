// 身份暗号（绊码）→ 发给服务端的派生密钥
//
// 1. 浏览器用 PBKDF2-SHA256（60 万次迭代）把暗号派生成 64 位十六进制串，
//    让每一次猜测都很慢；
// 2. 服务端再用只有数据库知道的 pepper 做 HMAC，得到真正的身份 token（见
//    supabase/migrations/20261010000100_p0_rpc_identity.sql）。
//
// 暗号本身从不离开浏览器，token 也不会再通过 API 暴露。
//
// ⚠️ 修改下面任意一个常量，所有人的暗号都会对应到新的号码。

const TRIPCODE_SALT = "pisces-tripcode-v1";
const TRIPCODE_ITERATIONS = 600_000;

export async function deriveTripcodeKey(secret: string): Promise<string> {
  const encoder = new TextEncoder();
  // NFC 归一化：同一个暗号在不同系统 / 输入法下得到相同结果
  const material = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret.normalize("NFC")),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const bits = await crypto.subtle.deriveBits(
    {
      name: "PBKDF2",
      hash: "SHA-256",
      salt: encoder.encode(TRIPCODE_SALT),
      iterations: TRIPCODE_ITERATIONS,
    },
    material,
    256,
  );
  return Array.from(new Uint8Array(bits), (b) => b.toString(16).padStart(2, "0")).join("");
}
