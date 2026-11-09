/** Public DTO data and the original HTTP response metadata. */
export class ApiResponse<T> {
  constructor(
    readonly data: T,
    readonly status: number,
    readonly headers: Headers,
  ) {}
}
