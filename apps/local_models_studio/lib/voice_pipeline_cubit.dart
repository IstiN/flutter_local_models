import 'package:flutter_bloc/flutter_bloc.dart';

enum VoicePipelinePhase { idle, transcribing, replying, synthesizing }

class VoicePipelineCubit extends Cubit<VoicePipelinePhase> {
  VoicePipelineCubit() : super(VoicePipelinePhase.idle);

  void setTranscribing() => emit(VoicePipelinePhase.transcribing);
  void setReplying() => emit(VoicePipelinePhase.replying);
  void setSynthesizing() => emit(VoicePipelinePhase.synthesizing);
  void reset() => emit(VoicePipelinePhase.idle);
}
