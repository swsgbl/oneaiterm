// Kubernetes 客户端:REST API(@ohos.net.http 纯 TS)
// 官方 K8sTab 子集:API server + Bearer Token,GET 查询 nodes/namespaces/pods/deployments
import http from '@ohos.net.http';

export class K8sService {
  private static server: string = ''
  private static token: string = ''

  static configure(server: string, token: string): void {
    K8sService.server = server.replace(/\/+$/, '')
    K8sService.token = token
  }

  static configured(): boolean {
    return K8sService.server !== ''
  }

  /** GET path(如 /api/v1/namespaces/default/pods),返回解析后的 JSON 文本 */
  static async get(path: string): Promise<string> {
    if (K8sService.server === '') {
      throw new Error('未配置 API server')
    }
    const url = K8sService.server + path
    return new Promise<string>((resolve, reject) => {
      const h = http.createHttp()
      h.request(url, {
        method: http.RequestMethod.GET,
        header: {
          'Authorization': 'Bearer ' + K8sService.token,
          'Accept': 'application/json'
        },
        connectTimeout: 10000,
        readTimeout: 15000,
        expectDataType: http.HttpDataType.STRING
      }, (err, resp) => {
        h.destroy()
        if (err) {
          reject(new Error(JSON.stringify(err).substring(0, 200)))
          return
        }
        const body = typeof resp.result === 'string' ? resp.result : ''
        if (resp.responseCode >= 400) {
          reject(new Error('HTTP ' + resp.responseCode + ': ' + body.substring(0, 300)))
          return
        }
        resolve(body)
      })
    })
  }

  /** 摘要 items[].metadata.name 列表 */
  static namesOf(json: string): string[] {
    class K8sItem { metadata: Record<string, string> = {} }
    class K8sList { items: K8sItem[] = [] }
    const obj = JSON.parse(json) as K8sList
    const out: string[] = []
    if (obj.items !== undefined && obj.items !== null) {
      for (const it of obj.items) {
        if (it.metadata !== undefined && it.metadata['name'] !== undefined) {
          out.push(it.metadata['name'])
        }
      }
    }
    return out
  }
}
