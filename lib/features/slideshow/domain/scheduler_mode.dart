enum SchedulerMode { adaptive, viewport }

SchedulerMode get currentSchedulerMode {
  const override = String.fromEnvironment('SCHEDULER_MODE');
  if (override == 'viewport') return SchedulerMode.viewport;
  return SchedulerMode.adaptive;
}

bool get isViewportSchedulerEnabled => currentSchedulerMode == SchedulerMode.viewport;
