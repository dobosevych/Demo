/**
 * The API client: the only place that knows the backend's URL and its response
 * shapes. Components call these functions; they never call `fetch` themselves.
 */

const RAW_URL: string = import.meta.env.VITE_API_URL ?? "";

/** `"/"` means same-origin: the API is served at `/api` on the site's own domain. */
const BASE_URL = RAW_URL.replace(/\/+$/, "");

/**
 * Whether this build was given a backend to talk to.
 *
 * A static deployment (CloudFront with no API behind it) builds with an empty
 * `VITE_API_URL`. The page must still render, so this is a flag the UI reads
 * rather than a throw at import time — a throw here blanks the whole app.
 */
export const apiConfigured = RAW_URL !== "";

/** One person. Shared by every meeting they attend; `email` is globally unique. */
export interface Participant {
  id: string;
  email: string;
  display_name: string;
}

export interface Meeting {
  id: string;
  title: string;
  description: string;
  /** ISO 8601, UTC, with an explicit Z. */
  starts_at: string;
  ends_at: string;
  participants: Participant[];
}

export interface MeetingCreate {
  title: string;
  description?: string;
  starts_at: string;
  ends_at: string;
  /** Email addresses, not objects: the backend resolves each to a participant. */
  participants?: string[];
}

export type MeetingUpdate = Partial<MeetingCreate>;

export interface ParticipantCreate {
  email: string;
  display_name?: string;
}

export interface ListMeetingsQuery {
  from?: string;
  to?: string;
  participant_id?: string;
  limit?: number;
  offset?: number;
}

/** Every error body is `{ "detail": ... }`, so there is one thing to parse. */
export class ApiError extends Error {
  readonly status: number;

  constructor(status: number, detail: string) {
    super(detail);
    this.name = "ApiError";
    this.status = status;
  }
}

type Detail = string | { msg?: string; loc?: (string | number)[] }[] | undefined;

function readDetail(detail: Detail, status: number): string {
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) {
    return detail
      .map((item) => {
        const field = item.loc?.filter((part) => part !== "body").join(".");
        return field ? `${field}: ${item.msg ?? "invalid"}` : (item.msg ?? "invalid");
      })
      .join("; ");
  }
  return `request failed with status ${status}`;
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  if (!apiConfigured) {
    throw new ApiError(0, "this deployment has no backend: VITE_API_URL was empty at build time");
  }

  const response = await fetch(`${BASE_URL}${path}`, {
    ...init,
    headers: init?.body ? { "Content-Type": "application/json", ...init?.headers } : init?.headers,
  });

  if (!response.ok) {
    let detail: Detail;
    try {
      detail = ((await response.json()) as { detail?: Detail }).detail;
    } catch {
      detail = undefined;
    }
    throw new ApiError(response.status, readDetail(detail, response.status));
  }

  if (response.status === 204) return undefined as T;
  return (await response.json()) as T;
}

function queryString(query: Record<string, string | number | undefined>): string {
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value !== undefined && value !== "") params.set(key, String(value));
  }
  const rendered = params.toString();
  return rendered ? `?${rendered}` : "";
}

export function listMeetings(query: ListMeetingsQuery = {}): Promise<Meeting[]> {
  return request<Meeting[]>(`/api/meetings${queryString({ ...query })}`);
}

export function createMeeting(payload: MeetingCreate): Promise<Meeting> {
  return request<Meeting>("/api/meetings", {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export function readMeeting(id: string): Promise<Meeting> {
  return request<Meeting>(`/api/meetings/${id}`);
}

export function updateMeeting(id: string, payload: MeetingUpdate): Promise<Meeting> {
  return request<Meeting>(`/api/meetings/${id}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
}

export function deleteMeeting(id: string): Promise<void> {
  return request<void>(`/api/meetings/${id}`, { method: "DELETE" });
}

/** Write one join row. Idempotent; never creates a participant. */
export function inviteParticipant(meetingId: string, participantId: string): Promise<void> {
  return request<void>(`/api/meetings/${meetingId}/participants/${participantId}`, {
    method: "PUT",
  });
}

/** Delete one join row. Idempotent; never deletes a participant. */
export function uninviteParticipant(meetingId: string, participantId: string): Promise<void> {
  return request<void>(`/api/meetings/${meetingId}/participants/${participantId}`, {
    method: "DELETE",
  });
}

export function listParticipants(
  query: { email?: string; limit?: number; offset?: number } = {},
): Promise<Participant[]> {
  return request<Participant[]>(`/api/participants${queryString({ ...query })}`);
}

export function createParticipant(payload: ParticipantCreate): Promise<Participant> {
  return request<Participant>("/api/participants", {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export function readParticipant(id: string): Promise<Participant> {
  return request<Participant>(`/api/participants/${id}`);
}

export function updateParticipant(id: string, display_name: string): Promise<Participant> {
  return request<Participant>(`/api/participants/${id}`, {
    method: "PATCH",
    body: JSON.stringify({ display_name }),
  });
}

export function deleteParticipant(id: string): Promise<void> {
  return request<void>(`/api/participants/${id}`, { method: "DELETE" });
}
