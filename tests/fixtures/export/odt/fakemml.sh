#!/bin/sh
# fake LaTeX -> MathML converter: $1 input file, $2 output file
printf 'junk<math xmlns="http://www.w3.org/1998/Math/MathML"><mtext>%s</mtext></math>\n' "$(tr -d '\n$\\' < "$1")" > "$2"
