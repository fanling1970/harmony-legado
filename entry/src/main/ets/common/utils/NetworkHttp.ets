/**
 * NetworkHttp —— 带自定义请求头与编码兼容的 GET 抓取
 */
import axios, { AxiosRequestConfig, AxiosResponse } from '@ohos/axios';
import { util } from '@kit.ArkTS';

export class NetworkHttp {
  static async getHtml(url: string, headers: Record<string, string>, charset: string = 'UTF-8'): Promise<string> {
    const options: AxiosRequestConfig = {
      headers: headers,
      responseType: 'array_buffer',
      timeout: 15000
    };
    const response: AxiosResponse<ArrayBuffer> = await axios.get<ArrayBuffer>(url, options);
    return NetworkHttp.decode(response.data, charset);
  }

  static async postHtml(url: string, body: string, headers: Record<string, string>,
    charset: string = 'UTF-8'): Promise<string> {
    const options: AxiosRequestConfig = {
      headers: headers,
      responseType: 'array_buffer',
      timeout: 15000
    };
    const response: AxiosResponse<ArrayBuffer> = await axios.post<ArrayBuffer>(url, body, options);
    return NetworkHttp.decode(response.data, charset);
  }

  private static decode(data: ArrayBuffer, encoding: string): string {
    const toDecode = (label: string): string | null => {
      try {
        const td = util.TextDecoder.create(label, { ignoreBOM: true });
        return td.decodeWithStream(new Uint8Array(data));
      } catch (e) {
        return null;
      }
    };
    let decoded = toDecode(/utf-?8/i.test(encoding) ? 'utf-8' : encoding);
    if (decoded === null) {
      decoded = toDecode('utf-8');
    }
    return decoded ?? '';
  }
}
