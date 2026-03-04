#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

static std::vector<std::vector<int>> read_csv_int_matrix(const std::string& path) {
    std::ifstream ifs(path);
    if (!ifs) {
        throw std::runtime_error("Failed to open: " + path);
    }
    std::vector<std::vector<int>> mat;
    std::string line;
    while (std::getline(ifs, line)) {
        if (line.empty()) continue;
        std::vector<int> row;
        std::stringstream ss(line);
        std::string cell;
        while (std::getline(ss, cell, ',')) {
            row.push_back(std::stoi(cell));
        }
        mat.push_back(std::move(row));
    }
    return mat;
}

static double q8_8_to_float(int x) {
    return static_cast<double>(x) / 256.0;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " <dump_dir>\n";
        return 2;
    }

    const std::string dump_dir = argv[1];
    const auto Q = read_csv_int_matrix(dump_dir + "/Q_q8_8.csv");
    const auto K = read_csv_int_matrix(dump_dir + "/K_q8_8.csv");
    const auto V = read_csv_int_matrix(dump_dir + "/V_q8_8.csv");
    const auto O_rtl = read_csv_int_matrix(dump_dir + "/O_rtl_q8_8.csv");

    const int S = static_cast<int>(Q.size());
    if (S == 0) {
        std::cerr << "Empty Q matrix\n";
        return 3;
    }
    const int D = static_cast<int>(Q[0].size());

    std::vector<std::vector<double>> O_ref(S, std::vector<double>(D, 0.0));
    const double scale = 1.0 / std::sqrt(static_cast<double>(D));

    for (int i = 0; i < S; ++i) {
        std::vector<double> scores(S, 0.0);
        double max_s = -1e30;

        for (int j = 0; j < S; ++j) {
            double dot = 0.0;
            for (int d = 0; d < D; ++d) {
                dot += q8_8_to_float(Q[i][d]) * q8_8_to_float(K[j][d]);
            }
            scores[j] = dot * scale;
            if (scores[j] > max_s) max_s = scores[j];
        }

        double denom = 0.0;
        std::vector<double> probs(S, 0.0);
        for (int j = 0; j < S; ++j) {
            probs[j] = std::exp(scores[j] - max_s);
            denom += probs[j];
        }
        for (int j = 0; j < S; ++j) {
            probs[j] /= denom;
        }

        for (int d = 0; d < D; ++d) {
            double acc = 0.0;
            for (int j = 0; j < S; ++j) {
                acc += probs[j] * q8_8_to_float(V[j][d]);
            }
            O_ref[i][d] = acc;
        }
    }

    double mae = 0.0;
    double max_ae = 0.0;
    long long count = 0;

    for (int i = 0; i < S; ++i) {
        for (int d = 0; d < D; ++d) {
            const double rtl_f = q8_8_to_float(O_rtl[i][d]);
            const double err = std::fabs(rtl_f - O_ref[i][d]);
            mae += err;
            if (err > max_ae) max_ae = err;
            ++count;
        }
    }

    mae /= static_cast<double>(count);

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "[C++ SDPA Compare] S=" << S << " D=" << D << "\n";
    std::cout << "[C++ SDPA Compare] MAE=" << mae << "\n";
    std::cout << "[C++ SDPA Compare] MAX_AE=" << max_ae << "\n";

    const bool pass_mae = mae <= 0.03;
    const bool pass_max = max_ae <= 0.10;
    std::cout << "[C++ SDPA Compare] Thresholds: MAE<=0.03 "
              << (pass_mae ? "PASS" : "FAIL")
              << ", MAX_AE<=0.10 "
              << (pass_max ? "PASS" : "FAIL") << "\n";

    return (pass_mae && pass_max) ? 0 : 1;
}
