// Files imported with `with { type: "text" }` (embedded in the compiled app).
declare module "*.md" {
  const text: string;
  export default text;
}
