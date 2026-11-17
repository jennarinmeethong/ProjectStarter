// Lets plain TypeScript tooling (ESLint's type checker) see .vue imports; vue-tsc checks the components themselves.
declare module "*.vue" {
  import type { DefineComponent } from "vue";
  const component: DefineComponent<object, object, unknown>;
  export default component;
}
