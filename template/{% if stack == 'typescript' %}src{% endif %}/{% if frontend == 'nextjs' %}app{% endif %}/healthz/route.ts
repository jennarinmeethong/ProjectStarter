// Liveness endpoint for the container smoke run and the ZAP scan (ci/dast.sh).
export function GET(): Response {
  return Response.json({ status: "ok" });
}
