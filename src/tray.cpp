// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "tray.h"

#include <KStatusNotifierItem>
#include <QIcon>

Tray::Tray(QObject *parent)
    : QObject(parent)
    , m_item(new KStatusNotifierItem(QStringLiteral("hafen"), this))
{
    m_item->setTitle(QStringLiteral("Hafen"));
    m_item->setCategory(KStatusNotifierItem::ApplicationStatus);
    m_item->setStatus(KStatusNotifierItem::Active);
    m_item->setIconByPixmap(QIcon(QStringLiteral(":/qt/qml/Hafen/data/hafen.svg")));
    m_item->setToolTipTitle(QStringLiteral("Hafen"));
}

QWindow *Tray::window() const
{
    return m_window;
}

void Tray::setWindow(QWindow *window)
{
    if (m_window == window) {
        return;
    }
    m_window = window;
    // With an associated window a left click on the tray icon shows or hides it.
    m_item->setAssociatedWindow(window);
    Q_EMIT windowChanged();
}

QString Tray::subtitle() const
{
    return m_subtitle;
}

void Tray::setSubtitle(const QString &subtitle)
{
    if (m_subtitle == subtitle) {
        return;
    }
    m_subtitle = subtitle;
    m_item->setToolTipSubTitle(subtitle);
    Q_EMIT subtitleChanged();
}

bool Tray::warning() const
{
    return m_warning;
}

void Tray::setWarning(bool warning)
{
    if (m_warning == warning) {
        return;
    }
    m_warning = warning;
    m_item->setOverlayIconByName(warning ? QStringLiteral("dialog-warning") : QString());
    Q_EMIT warningChanged();
}

void Tray::notify(const QString &title, const QString &body, const QString &iconName)
{
    m_item->showMessage(title, body, iconName);
}
