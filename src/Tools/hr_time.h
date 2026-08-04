#ifndef HR_TIME_H
#define HR_TIME_H

#include <chrono>
#include <QtGlobal>

#ifdef Q_OS_WIN
#include <windows.h>
#endif

class CStopWatch {
private:
#ifdef Q_OS_WIN
    LARGE_INTEGER startTime;
    LARGE_INTEGER stopTime;
    LARGE_INTEGER frequency;
#else
    std::chrono::steady_clock::time_point startTime;
    std::chrono::steady_clock::time_point stopTime;
#endif
public:
    CStopWatch();
    void startTimer();
    void stopTimer();
    double getElapsedTime();
};

#endif // HR_TIME_H
