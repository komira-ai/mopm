/**
 * `PUT /api/v2/packages/{namespace}/{name}` (createPackage, docs/design/namespaces.md section 8): create a package in a
 * namespace the caller can write. 201 created, 200 when it exists.
 */
export class CreateService {
  async create(_authorization: string | undefined, _namespace: string, _name: string): Promise<{ created: boolean }> {
    throw new Error('CreateService.create: not implemented');
  }
}
