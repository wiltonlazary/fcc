module reduce;

template reduce(T) <<EOF
  alias itersample = (init!T)[0];
  alias stepsample = init!type-of __istep itersample;
  alias dgsample = (init!T)[1];
  alias callsample = dgsample(stepsample, stepsample);
  type-of callsample delegate(type-of stepsample) reduce(T t) {
    return new delegate type-of callsample(type-of stepsample start) {
      auto cur = start;
      while auto var <- t[0] {
        cur = t[1](cur, var);
      }
      return cur;
    };
  }
EOF

void main() {
  auto res = reduce (0..10, delegate int(int a, b) return a+b;) 0;
  writeln " => $res";
}