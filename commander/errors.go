package commander

import "net/http"

type APIError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}
type Result struct {
	Status     int       `json:"-"`
	OK         bool      `json:"ok,omitempty"`
	Command    string    `json:"command,omitempty"`
	RequestID  string    `json:"requestId,omitempty"`
	Error      *APIError `json:"error,omitempty"`
	RetryAfter int       `json:"-"`
}

func failure(status int, code, message string) Result {
	return Result{Status: status, Error: &APIError{code, message}}
}
func unavailable() Result {
	return failure(http.StatusNotImplemented, "commands_unavailable", "Vehicle commands are not enabled.")
}
