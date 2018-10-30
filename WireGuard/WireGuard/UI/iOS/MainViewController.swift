// SPDX-License-Identifier: MIT
// Copyright © 2018 WireGuard LLC. All Rights Reserved.

import UIKit

class MainViewController: UISplitViewController {
    var tunnelsListVC: TunnelsListTableViewController?

    override func loadView() {
        let detailVC = UIViewController()
        let detailNC = UINavigationController(rootViewController: detailVC)

        let masterVC = TunnelsListTableViewController()
        let masterNC = UINavigationController(rootViewController: masterVC)

        self.viewControllers = [ masterNC, detailNC ]

        super.loadView()

        tunnelsListVC = masterVC
    }

    override func viewDidLoad() {
        self.delegate = self

        // On iPad, always show both masterVC and detailVC, even in portrait mode, like the Settings app
        self.preferredDisplayMode = .allVisible
    }

    func openForEditing(configFileURL: URL) {
        tunnelsListVC?.openForEditing(configFileURL: configFileURL)
    }
}

extension MainViewController: UISplitViewControllerDelegate {
    func splitViewController(_ splitViewController: UISplitViewController,
                             collapseSecondary secondaryViewController: UIViewController,
                             onto primaryViewController: UIViewController) -> Bool {
        // On iPhone, if the secondaryVC (detailVC) is just a UIViewController, it indicates that it's empty,
        // so just show the primaryVC (masterVC).
        let detailVC = (secondaryViewController as? UINavigationController)?.viewControllers.first
        let isDetailVCEmpty: Bool
        if let detailVC = detailVC {
            isDetailVCEmpty = (type(of: detailVC) == UIViewController.self)
        } else {
            isDetailVCEmpty = true
        }
        return isDetailVCEmpty
    }
}
