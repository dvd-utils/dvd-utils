#include "hr_time.h"

CStopWatch::CStopWatch()
{
#ifdef Q_OS_WIN
    startTime.QuadPart = 0;
    stopTime.QuadPart = 0;
    QueryPerformanceFrequency(&frequency);
#else
    startTime = std::chrono::steady_clock::time_point{};
    stopTime = std::chrono::steady_clock::time_point{};
#endif
}

void CStopWatch::startTimer()
{
#ifdef Q_OS_WIN
    QueryPerformanceCounter(&startTime);
#else
    startTime = std::chrono::steady_clock::now();
#endif
}

void CStopWatch::stopTimer()
{
#ifdef Q_OS_WIN
    QueryPerformanceCounter(&stopTime);
#else
    stopTime = std::chrono::steady_clock::now();
#endif
}

double CStopWatch::getElapsedTime()
{
#ifdef Q_OS_WIN
    const double elapsed = static_cast<double>(stopTime.QuadPart - startTime.QuadPart);
    return elapsed / static_cast<double>(frequency.QuadPart);
#else
    const auto elapsed = std::chrono::duration<double>(stopTime - startTime);
    return elapsed.count();
#endif
}
