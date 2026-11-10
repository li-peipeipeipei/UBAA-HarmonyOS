import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';
import { ApiError } from '../network/ApiError';

/**
 * 博雅课程（bykc）的报文加密 —— 照抄原版 UBAA 的 `LocalBykcCrypto`。
 *
 * ## 协议
 *
 * 每个请求临时生成一把 16 字节 AES 密钥，然后：
 * - `body` = **Base64(AES-ECB/PKCS5(明文 JSON))**；
 * - 请求头 `ak` = **RSA(aesKey)**、`sk` = **RSA(sha1Hex(明文))**、`ts` = 毫秒时间戳；
 * - 响应体同样是 Base64 密文，**用同一把 aesKey 解密**。
 *
 * RSA 公钥是**硬编码**的（原版就这么写），所以不需要额外的配置接口。
 *
 * ## 为什么 AES 用 NoPadding、自己补 PKCS#5
 *
 * `createCipher` 的 spec 字符串（`AES128|ECB|PKCS5` 这类）是**运行期校验**的，
 * 各版本对 padding 标签的写法不完全一致；用 `NoPadding` + 自己补/去填充，行为完全确定。
 */
const RSA_PUBLIC_KEY_DER_BASE64: string =
  'MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDlHMQ3B5GsWnCe7Nlo1YiG/YmHdlOiKOST5aRm4iaqYSvhvWmwcigoyWTM' +
    '+8bv2+sf6nQBRDWTY4KmNV7DBk1eDnTIQo6ENA31k5/tYCLEXgjPbEjCK9spiyB62fCT6cqOhbamJB0lcDJRO6Vo1m3dy' +
    '+fD0jbxfDVBBNtyltIsDQIDAQAB';

/** AES 密钥字符集（与原版一致：剔除了 0/O/1/l 这类易混字符）。 */
const AES_KEY_CHARS: string = 'ABCDEFGHJKMNPQRSTWXYZabcdefhijkmnprstwxyz2345678';
const AES_KEY_LENGTH: number = 16;
const AES_BLOCK_SIZE: number = 16;

/** 一次请求用到的加密材料。 */
export interface BykcEncryptedRequest {
  /** Base64(AES(明文))，直接当请求体发出去。 */
  encryptedData: string;
  /** RSA(aesKey)。 */
  ak: string;
  /** RSA(sha1Hex(明文))。 */
  sk: string;
  /** 毫秒时间戳。 */
  ts: string;
  /** 解密响应要用的同一把密钥。 */
  aesKey: Uint8Array;
}

export class BykcCrypto {
  /** 导入一次 RSA 公钥后缓存（1024 位公钥的导入不便宜，别每个请求都做）。 */
  private static publicKeyCache: cryptoFramework.PubKey | null = null;

  /** 组一次请求的加密材料。 */
  static async encryptRequest(jsonText: string): Promise<BykcEncryptedRequest> {
    try {
      const aesKey: Uint8Array = BykcCrypto.randomAesKey();
      const plain: Uint8Array = new util.TextEncoder().encodeInto(jsonText);
      const cipherBytes: Uint8Array = await BykcCrypto.aesCipher(true, plain, aesKey);
      const sha1: string = await BykcCrypto.sha1Hex(plain);
      const ak: string = await BykcCrypto.rsaEncryptBase64(aesKey);
      const sk: string = await BykcCrypto.rsaEncryptBase64(new util.TextEncoder().encodeInto(sha1));
      return {
        encryptedData: new util.Base64Helper().encodeToStringSync(cipherBytes),
        ak: ak,
        sk: sk,
        ts: Date.now().toString(),
        aesKey: aesKey
      };
    } catch (error) {
      Logger.error('博雅报文加密失败：' + (error as Error).message);
      throw new ApiError(502, 'bykc_crypto', '博雅课程加密失败，请稍后重试');
    }
  }

  /** 解密响应体（Base64 密文 → 明文 JSON）。 */
  static async decryptResponse(base64Text: string, aesKey: Uint8Array): Promise<string> {
    const cipherBytes: Uint8Array = new util.Base64Helper().decodeSync(base64Text);
    const plain: Uint8Array = await BykcCrypto.aesCipher(false, cipherBytes, aesKey);
    return new util.TextDecoder().decodeToString(plain);
  }

  /* ------------------------------ 内部 ------------------------------ */

  private static randomAesKey(): Uint8Array {
    const key = new Uint8Array(AES_KEY_LENGTH);
    for (let i = 0; i < AES_KEY_LENGTH; i++) {
      key[i] = AES_KEY_CHARS.charCodeAt(Math.floor(Math.random() * AES_KEY_CHARS.length));
    }
    return key;
  }

  /** PKCS#5 填充：补 `16 - len % 16` 个「填充长度」字节。 */
  private static pad(data: Uint8Array): Uint8Array {
    const padLength: number = AES_BLOCK_SIZE - (data.length % AES_BLOCK_SIZE);
    const padded = new Uint8Array(data.length + padLength);
    padded.set(data, 0);
    for (let i = data.length; i < padded.length; i++) {
      padded[i] = padLength;
    }
    return padded;
  }

  /** 去掉 PKCS#5 填充；填充不合法时原样返回（宁可给出错文本，也别把数据截断）。 */
  private static unpad(data: Uint8Array): Uint8Array {
    if (data.length === 0) {
      return data;
    }
    const padLength: number = data[data.length - 1];
    if (padLength === 0 || padLength > AES_BLOCK_SIZE || padLength > data.length) {
      return data;
    }
    return data.slice(0, data.length - padLength);
  }

  private static async aesCipher(
    encrypt: boolean,
    data: Uint8Array,
    key: Uint8Array
  ): Promise<Uint8Array> {
    const generator = cryptoFramework.createSymKeyGenerator('AES128');
    const symKey = await generator.convertKey({ data: key });
    // 见文件头：NoPadding + 自己补填充，避开 spec 字符串的版本差异
    const cipher = cryptoFramework.createCipher('AES128|ECB|NoPadding');
    await cipher.init(
      encrypt ? cryptoFramework.CryptoMode.ENCRYPT_MODE : cryptoFramework.CryptoMode.DECRYPT_MODE,
      symKey,
      null
    );
    const input: Uint8Array = encrypt ? BykcCrypto.pad(data) : data;
    const output = await cipher.doFinal({ data: input });
    const result = new Uint8Array(output.data);
    return encrypt ? result : BykcCrypto.unpad(result);
  }

  /** SHA-1 摘要的十六进制串（上游 `sk` 里的那一段）。 */
  private static async sha1Hex(data: Uint8Array): Promise<string> {
    const md = cryptoFramework.createMd('SHA1');
    await md.update({ data: data });
    const digest = await md.digest();
    const bytes = new Uint8Array(digest.data);
    let text: string = '';
    for (let i = 0; i < bytes.length; i++) {
      const hex: string = bytes[i].toString(16);
      text += hex.length === 1 ? '0' + hex : hex;
    }
    return text;
  }

  /** RSA/PKCS#1 加密后 Base64（`ak` / `sk` 都用它）。 */
  private static async rsaEncryptBase64(data: Uint8Array): Promise<string> {
    const publicKey: cryptoFramework.PubKey = await BykcCrypto.rsaPublicKey();
    const cipher = cryptoFramework.createCipher('RSA1024|PKCS1');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, publicKey, null);
    const output = await cipher.doFinal({ data: data });
    return new util.Base64Helper().encodeToStringSync(new Uint8Array(output.data));
  }

  /**
   * 导入并缓存 RSA 公钥。
   *
   * 公钥是 **DER / X.509 SubjectPublicKeyInfo**（原版就是直接 Base64 解出来用的），
   * 所以这里 `convertKey(公钥, null)` 一次即可。
   */
  private static async rsaPublicKey(): Promise<cryptoFramework.PubKey> {
    const cached = BykcCrypto.publicKeyCache;
    if (cached !== null) {
      return cached;
    }
    const der: Uint8Array = new util.Base64Helper().decodeSync(RSA_PUBLIC_KEY_DER_BASE64);
    const generator = cryptoFramework.createAsyKeyGenerator('RSA1024');
    const keyPair: cryptoFramework.KeyPair = await generator.convertKey({ data: der }, null);
    BykcCrypto.publicKeyCache = keyPair.pubKey;
    return keyPair.pubKey;
  }
}
