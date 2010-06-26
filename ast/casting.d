module ast.casting;

import ast.base, ast.parse;

class ReinterpretCast(T) : T {
  T from; Type to;
  this(Type to, T from) { this.from = from; this.to = to; }
  mixin defaultIterate!(from);
  override {
    string toString() { return Format("reinterpret_cast<", to, "> ", from); }
    Type valueType() { return to; }
    void emitAsm(AsmFile af) {
      from.emitAsm(af);
    }
    static if (is(typeof(&from.emitLocation)))
      void emitLocation(AsmFile af) {
        from.emitLocation(af);
      }
  }
}
