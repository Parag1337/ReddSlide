import 'readiness_state.dart';

class DemandCalculator {
  const DemandCalculator();

  static const double _likelyReadyWeight = 0.5;

  int computeNeedCount(List<ReadinessState> states, {required int targetBudget}) {
    if (targetBudget <= 0) return 0;
    double score = 0;
    for (final state in states) {
      switch (state) {
        case ReadinessState.ready:
          score += 1.0;
        case ReadinessState.likelyReady:
          score += _likelyReadyWeight;
        case ReadinessState.unavailable:
          break;
      }
    }
    final need = targetBudget - score.ceil();
    return need > 0 ? need : 0;
  }
}
