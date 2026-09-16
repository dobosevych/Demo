import { CalendarDays, Loader2, Trash2, Users, X } from "lucide-react";
import { useCallback, useEffect, useState, type FormEvent } from "react";

import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import {
  ApiError,
  apiConfigured,
  createMeeting,
  deleteMeeting,
  listMeetings,
  uninviteParticipant,
  type Meeting,
} from "@/lib/api";

/** `datetime-local` gives a local wall clock; the API wants UTC with a Z. */
function toUtcIso(localValue: string): string {
  return new Date(localValue).toISOString();
}

/** One hour from now, rounded down to the half hour, as a `datetime-local` value. */
function defaultSlot(offsetMinutes: number): string {
  const date = new Date(Date.now() + offsetMinutes * 60_000);
  date.setMinutes(date.getMinutes() < 30 ? 0 : 30, 0, 0);
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(
    date.getHours(),
  )}:${pad(date.getMinutes())}`;
}

const dateFormat = new Intl.DateTimeFormat(undefined, {
  dateStyle: "medium",
  timeStyle: "short",
});

function formatSlot(meeting: Meeting): string {
  const starts = new Date(meeting.starts_at);
  const ends = new Date(meeting.ends_at);
  const endTime = new Intl.DateTimeFormat(undefined, { timeStyle: "short" }).format(ends);
  return `${dateFormat.format(starts)} – ${endTime}`;
}

/** Emails typed one per line or separated by commas. */
function splitEmails(raw: string): string[] {
  return raw
    .split(/[\s,;]+/)
    .map((value) => value.trim())
    .filter(Boolean);
}

export default function App() {
  const [meetings, setMeetings] = useState<Meeting[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [startsAt, setStartsAt] = useState(() => defaultSlot(60));
  const [endsAt, setEndsAt] = useState(() => defaultSlot(120));
  const [participants, setParticipants] = useState("");

  const refresh = useCallback(async () => {
    if (!apiConfigured) {
      setLoading(false);
      return;
    }
    setLoading(true);
    try {
      setMeetings(await listMeetings());
      setError(null);
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : "the API is not reachable");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  async function handleCreate(event: FormEvent) {
    event.preventDefault();
    setSaving(true);
    try {
      await createMeeting({
        title,
        description,
        starts_at: toUtcIso(startsAt),
        ends_at: toUtcIso(endsAt),
        participants: splitEmails(participants),
      });
      setTitle("");
      setDescription("");
      setParticipants("");
      setError(null);
      await refresh();
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : "could not create the meeting");
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete(meeting: Meeting) {
    try {
      await deleteMeeting(meeting.id);
      await refresh();
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : "could not delete the meeting");
    }
  }

  async function handleUninvite(meetingId: string, participantId: string) {
    try {
      await uninviteParticipant(meetingId, participantId);
      await refresh();
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : "could not update the invitees");
    }
  }

  return (
    <main className="mx-auto flex w-full max-w-3xl flex-col gap-6 px-4 py-10">
      <header className="flex flex-col gap-1">
        <h1 className="text-2xl font-semibold tracking-tight">Meetings</h1>
        <p className="text-sm text-muted-foreground">
          Invite people by email. The same address is always the same person.
        </p>
      </header>

      {!apiConfigured ? (
        <div className="rounded-md border border-input bg-muted px-4 py-3 text-sm text-muted-foreground">
          <strong className="font-medium text-foreground">Static deployment.</strong> This build
          has no backend, so nothing can be listed or saved. The page itself is live.
        </div>
      ) : null}

      {error ? (
        <div className="rounded-md border border-destructive/40 bg-destructive/10 px-4 py-3 text-sm text-destructive">
          {error}
        </div>
      ) : null}

      <Card>
        <CardHeader>
          <CardTitle>New meeting</CardTitle>
          <CardDescription>All times are entered in your local timezone.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="flex flex-col gap-4" onSubmit={handleCreate}>
            <div className="flex flex-col gap-2">
              <Label htmlFor="title">Title</Label>
              <Input
                id="title"
                required
                maxLength={200}
                value={title}
                placeholder="Sprint planning"
                onChange={(event) => setTitle(event.target.value)}
              />
            </div>

            <div className="flex flex-col gap-2">
              <Label htmlFor="description">Description</Label>
              <Textarea
                id="description"
                maxLength={2000}
                value={description}
                placeholder="Groom the backlog, size the top ten items."
                onChange={(event) => setDescription(event.target.value)}
              />
            </div>

            <div className="grid gap-4 sm:grid-cols-2">
              <div className="flex flex-col gap-2">
                <Label htmlFor="starts_at">Starts</Label>
                <Input
                  id="starts_at"
                  type="datetime-local"
                  required
                  value={startsAt}
                  onChange={(event) => setStartsAt(event.target.value)}
                />
              </div>
              <div className="flex flex-col gap-2">
                <Label htmlFor="ends_at">Ends</Label>
                <Input
                  id="ends_at"
                  type="datetime-local"
                  required
                  value={endsAt}
                  onChange={(event) => setEndsAt(event.target.value)}
                />
              </div>
            </div>

            <div className="flex flex-col gap-2">
              <Label htmlFor="participants">Participants</Label>
              <Textarea
                id="participants"
                value={participants}
                placeholder="ada@example.com, alan@example.com"
                onChange={(event) => setParticipants(event.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                One address per line, or separated by commas.
              </p>
            </div>

            <div>
              <Button type="submit" disabled={saving || !apiConfigured}>
                {saving ? <Loader2 className="animate-spin" /> : <CalendarDays />}
                Create meeting
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>

      <section className="flex flex-col gap-3">
        <h2 className="text-lg font-semibold tracking-tight">Scheduled</h2>

        {loading ? (
          <p className="text-sm text-muted-foreground">Loading…</p>
        ) : meetings.length === 0 ? (
          <p className="text-sm text-muted-foreground">
            {apiConfigured ? "Nothing scheduled yet." : "No backend to read meetings from."}
          </p>
        ) : (
          meetings.map((meeting) => (
            <Card key={meeting.id}>
              <CardHeader className="flex-row items-start justify-between gap-4 space-y-0">
                <div className="flex flex-col gap-1">
                  <CardTitle>{meeting.title}</CardTitle>
                  <CardDescription>{formatSlot(meeting)}</CardDescription>
                </div>
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label={`Delete ${meeting.title}`}
                  onClick={() => void handleDelete(meeting)}
                >
                  <Trash2 />
                </Button>
              </CardHeader>
              <CardContent className="flex flex-col gap-3">
                {meeting.description ? (
                  <p className="text-sm whitespace-pre-line">{meeting.description}</p>
                ) : null}

                <div className="flex flex-wrap items-center gap-2">
                  <Users className="size-4 text-muted-foreground" />
                  {meeting.participants.length === 0 ? (
                    <span className="text-sm text-muted-foreground">No one invited yet.</span>
                  ) : (
                    meeting.participants.map((participant) => (
                      <Badge key={participant.id} variant="secondary">
                        {participant.display_name || participant.email}
                        <button
                          type="button"
                          aria-label={`Remove ${participant.email}`}
                          className="opacity-60 hover:opacity-100"
                          onClick={() => void handleUninvite(meeting.id, participant.id)}
                        >
                          <X className="size-3" />
                        </button>
                      </Badge>
                    ))
                  )}
                </div>
              </CardContent>
            </Card>
          ))
        )}
      </section>
    </main>
  );
}
