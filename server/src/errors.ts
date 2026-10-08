export class ApiError extends Error {
  constructor(public status: 400 | 401 | 404 | 409 | 413 | 429 | 501 | 503, public code: string, message: string) { super(message); }
}
export const missing = () => new ApiError(404, 'not_found', 'Resource not found');
export const invalid = (message: string) => new ApiError(400, 'invalid_input', message);
