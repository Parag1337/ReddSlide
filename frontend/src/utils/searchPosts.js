/**
 * Pure search over a multi-subreddit combined posts array.
 * - Case-insensitive substring match on title + content/selftext.
 * - Preserves original order.
 * - Handles missing fields safely.
 */
export function searchPosts(posts, query) {
  if (!Array.isArray(posts)) return [];
  const q = typeof query === "string" ? query.trim().toLowerCase() : "";
  if (!q) return posts;

  const out = [];
  for (let i = 0; i < posts.length; i++) {
    const p = posts[i];
    if (!p) continue;

    const title = typeof p.title === "string" ? p.title : "";
    const content =
      typeof p.content === "string"
        ? p.content
        : typeof p.selftext === "string"
          ? p.selftext
          : "";

    if ((title && title.toLowerCase().includes(q)) || (content && content.toLowerCase().includes(q))) {
      out.push(p);
    }
  }
  return out;
}

