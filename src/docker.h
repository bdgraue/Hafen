// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QJSValue>
#include <QObject>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class Docker : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int cpuCount READ cpuCount CONSTANT)
    Q_PROPERTY(double memoryTotal READ memoryTotal CONSTANT)

public:
    using QObject::QObject;

    // Runs the docker CLI without blocking and calls back with (exitCode, stdout, stderr).
    // exitCode is -2 when docker could not be started at all and -1 when it crashed or was killed after timeoutMs;
    // stderr then holds the reason. timeoutMs 0 waits as long as docker takes, e.g. for `compose up` pulling images.
    Q_INVOKABLE void run(const QStringList &args, const QJSValue &callback, int timeoutMs);

    int cpuCount() const;
    // Bytes of physical memory, from /proc/meminfo.
    double memoryTotal() const;
};
