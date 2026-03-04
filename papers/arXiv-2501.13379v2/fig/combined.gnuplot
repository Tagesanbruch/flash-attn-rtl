set terminal pdfcairo size 17cm,6cm enhanced font 'Latin Modern Roman,10'
set output 'taylor_vs_linear_subplot.pdf'

# --- Data blocks ---
$EXACT << EOD
# Bandwidth BRAM DSP FF LUT TIME
8          5.56 5.13   4.41  12.27 1.14975
12         10.42 12.82 12.09 24.86 1.17165
16         10.42 12.82 10.61 22.94 1.17165
24         84.72 51.28 25.49 34.69 1.19355
32         84.72 56.41 28.83 38.00 1.19355
EOD

$TAYLOR << EOD
# Bandwidth BRAM DSP FF LUT TIME
8          5.56 7.69 4.77 11.53 1.17165
12         10.42 10.26 7.08 13.73 1.17165
16         10.42 7.69 8.76 21.49 1.14975
24         20.14 17.95 18.25 37.41 1.19355
32         20.14 66.67 31.97 36.79 1.21545
EOD

$LINEAR << EOD
# Bandwidth BRAM DSP FF LUT TIME
8          5.56 12.82 6.47 15.48 1.23735
12         10.42 15.38 8.78 18.08 1.23735
16         10.42 17.95 10.42 19.19 1.23735
24         20.14 28.21 16.87 27.31 1.23735
32         40.28 56.41 23.05 33.68 1.23735
EOD

# Common settings
set style data histogram
set style histogram cluster gap 1
set style fill solid border -1
set boxwidth 0.9
set key at screen 0.45,0.05 center horizontal columns 5
set ytics nomirror
set bmargin 5
set yrange [0.0:90]

# --------------------------
# MULTIPLOT LAYOUT 2x1
# --------------------------
set multiplot layout 1,3

# --- Exact ---
set title "Exact hls::exp"
set xlabel "Data Lenght (bits)"
set ylabel "Resource Usage (%)"
# Set secondary y-axis for execution time
set y2range [1.10:1.30]
set y2tics
set grid ytics

plot $EXACT using 2:xtic(1) title "BRAM" lc rgb "skyblue", \
     '' using 3 title "DSP" lc rgb "orange", \
     '' using 4 title "FF" lc rgb "light-green", \
     '' using 5 title "LUT" lc rgb "purple", \
     '' using 6 with linespoints axes x1y2 lw 2 lc rgb "red" title "Exec Time (us)"

# --- Taylor Approximation ---
set title "Taylor Approximation"
set xlabel "Data Lenght (bits)"
# Set secondary y-axis for execution time
set y2range [1.10:1.30]
set y2tics
unset ylabel
set grid ytics

plot $TAYLOR using 2:xtic(1) title "BRAM" lc rgb "skyblue", \
     '' using 3 title "DSP" lc rgb "orange", \
     '' using 4 title "FF" lc rgb "light-green", \
     '' using 5 title "LUT" lc rgb "purple", \
     '' using 6 with linespoints axes x1y2 lw 2 lc rgb "red" title "Exec Time (us)"

# --- Linear Interpolation ---
set title "Linear Interpolation"
set xlabel "Data Lenght (bits)"
set xtics
# Set secondary y-axis for execution time
set y2label "Execution Time (us)"
unset ylabel
set y2range [1.10:1.30]
set y2tics
set grid ytics

plot $LINEAR using 2:xtic(1) notitle "BRAM" lc rgb "skyblue", \
     '' using 3 notitle "DSP" lc rgb "orange", \
     '' using 4 notitle "FF" lc rgb "light-green", \
     '' using 5 notitle "LUT" lc rgb "purple", \
     '' using 6 with linespoints axes x1y2 lw 2 lc rgb "red" notitle "Exec Time (us)"

unset multiplot
